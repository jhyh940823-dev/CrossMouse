using System.Diagnostics;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text.Json;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

/// <summary>
/// An opt-in, admin-installed session broker. No listener or windows in session
/// zero. The broker launches only this protected executable with one fixed mode
/// in the physical console session. It never logs or stores Windows passwords.
/// </summary>
internal sealed class SystemService : ServiceBase
{
    internal const string NameOnSystem = "CrossMouseInput";
    internal static string InstallDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "CrossMouse");
    internal static string Executable => Path.Combine(InstallDirectory, "CrossMouse.exe");
    internal static string DataDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "CrossMouse");
    internal static string ConfigurationPath => Path.Combine(DataDirectory, "service.json");
    private readonly CancellationTokenSource _stop = new();
    private Task? _broker;

    private SystemService()
    { ServiceName = NameOnSystem; CanStop = true; CanShutdown = true; AutoLog = false; }

    internal static int RunService()
    {
        if (!WindowsIdentity.GetCurrent().IsSystem || !IsProtectedExecutable()) return 5;
        Run(new SystemService());
        return 0;
    }
    internal static bool IsProtectedExecutable() => string.Equals(Path.GetFullPath(Environment.ProcessPath ?? ""),
        Executable, StringComparison.OrdinalIgnoreCase);
    internal static bool Installed => File.Exists(ConfigurationPath) && File.Exists(Executable);
    internal static bool Running
    {
        get
        {
            try { using var service = new ServiceController(NameOnSystem); return service.Status is ServiceControllerStatus.Running or ServiceControllerStatus.StartPending; }
            catch (InvalidOperationException) { return false; }
            catch (System.ComponentModel.Win32Exception) { return false; }
        }
    }
    internal static int Control(bool start)
    {
        if (!IsProtectedExecutable() || !new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) return 5;
        using var service = new ServiceController(NameOnSystem);
        if (start && service.Status != ServiceControllerStatus.Running) service.Start();
        if (!start && service.Status != ServiceControllerStatus.Stopped) service.Stop();
        service.WaitForStatus(start ? ServiceControllerStatus.Running : ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(15));
        return 0;
    }
    internal static async Task<bool> RequestControlAsync(bool start)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(Executable,
                start ? "--start-service" : "--stop-service") { UseShellExecute = true, Verb = "runas" });
            if (process is null) return false;
            await process.WaitForExitAsync();
            return process.ExitCode == 0;
        }
        catch (System.ComponentModel.Win32Exception) { return false; }
    }

    protected override void OnStart(string[] args)
    {
        _ = ReadConfiguration(); // invalid installation fails closed before spawning
        _broker = Task.Run(async () =>
        {
            ConsoleSessionProcess? worker = null;
            try
            {
                while (!_stop.IsCancellationRequested)
                {
                    uint session = ConsoleSessionProcess.ActiveSession;
                    if (worker is not null && (worker.SessionId != session || worker.HasExited))
                    { worker.Dispose(); worker = null; }
                    if (worker is null && session != uint.MaxValue && session != 0)
                    {
                        try { worker = ConsoleSessionProcess.Start(Executable, session); }
                        catch (Exception error) { RecordServiceFailure("agent-start", error.GetType().Name); }
                    }
                    await Task.Delay(1000, _stop.Token).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) { }
            finally { worker?.Dispose(); }
        });
    }
    protected override void OnStop()
    {
        _stop.Cancel();
        _broker?.Wait(TimeSpan.FromSeconds(5));
    }
    protected override void OnShutdown() => OnStop();
    protected override void Dispose(bool disposing)
    { if (disposing) _stop.Dispose(); base.Dispose(disposing); }

    internal sealed record Configuration(int Port, string OwnerSid, bool AllowLocalTestPeer = false);
    internal static Configuration ReadConfiguration()
    {
        var bytes = File.ReadAllBytes(ConfigurationPath);
        if (bytes.Length > 4096) throw new InvalidDataException("Oversized service configuration.");
        var config = JsonSerializer.Deserialize<Configuration>(bytes) ?? throw new InvalidDataException("Missing service configuration.");
        if (config.Port is < 1024 or > 65535) throw new InvalidDataException("Invalid service port.");
        _ = new SecurityIdentifier(config.OwnerSid);
        return config;
    }

    internal static async Task<int> RunSessionAgentAsync()
    {
        if (!WindowsIdentity.GetCurrent().IsSystem || !IsProtectedExecutable() ||
            Process.GetCurrentProcess().SessionId != ConsoleSessionProcess.ActiveSession) return 5;
        var config = ReadConfiguration();
        byte[] key = Convert.FromHexString(File.ReadAllText(Path.Combine(DataDirectory, "key")).Trim());
        if (key.Length != 32) return 6;
        using var stop = new CancellationTokenSource();
        await using var receiver = new ReceiverService(key, config.Port, rejectLocalPeers: !config.AllowLocalTestPeer);
        int state = (int)ReceiverState.Stopped;
        receiver.StatusChanged += (next, _) => Volatile.Write(ref state, (int)next);
        receiver.Start();
        Task control = ServiceControlPipe.ServeAsync(config.OwnerSid, receiver, stop.Token);
        try
        {
            while (Process.GetCurrentProcess().SessionId == ConsoleSessionProcess.ActiveSession && Running)
            {
                WriteStatus((ReceiverState)Volatile.Read(ref state), receiver);
                if (control.IsFaulted) await control.ConfigureAwait(false);
                await Task.Delay(500, stop.Token).ConfigureAwait(false);
            }
        }
        finally
        {
            stop.Cancel();
            try { await control.ConfigureAwait(false); } catch (OperationCanceledException) { }
            await receiver.StopAsync().ConfigureAwait(false);
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(key);
        }
        return 0;
    }

    internal sealed record Status(DateTime UpdatedUtc, int AgentPid, int SessionId, string Version,
        string State, bool Active, string? Desktop, string? Fault);
    private static void WriteStatus(ReceiverState state, ReceiverService receiver)
    {
        try
        {
            var status = new Status(DateTime.UtcNow, Environment.ProcessId, Process.GetCurrentProcess().SessionId,
                typeof(SystemService).Assembly.GetName().Version?.ToString(3) ?? "unknown", state.ToString(),
                receiver.IsRemotelyActive, InputDesktopAccess.CurrentName(), receiver.InputFailure);
            var path = Path.Combine(DataDirectory, "status.json");
            File.WriteAllBytes(path + ".tmp", JsonSerializer.SerializeToUtf8Bytes(status));
            File.Move(path + ".tmp", path, true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
    internal static Status? ReadStatus()
    {
        try
        {
            var file = new FileInfo(Path.Combine(DataDirectory, "status.json"));
            if (!file.Exists || file.Length > 8192) return null;
            var status = JsonSerializer.Deserialize<Status>(File.ReadAllBytes(file.FullName));
            return status is not null && DateTime.UtcNow - status.UpdatedUtc < TimeSpan.FromSeconds(4) ? status : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }
    private static void RecordServiceFailure(string stage, string kind)
    {
        try
        {
            // Last error only: no unbounded SYSTEM log and no secrets/commands.
            File.WriteAllText(Path.Combine(DataDirectory, "last-error.txt"), $"{DateTime.UtcNow:O} {stage}: {kind}");
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

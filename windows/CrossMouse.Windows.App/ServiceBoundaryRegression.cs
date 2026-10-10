using System.Drawing;
using System.Runtime.InteropServices;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

/// <summary>
/// CI-only integration against the installed SYSTEM broker/session agent.
/// Uses a fresh isolated desktop and a form owned by this test; never logs off,
/// enters passwords, clicks UAC, touches monitor inputs, or changes UAC policy.
/// Always switches back to the original desktop in finally.
/// </summary>
internal static class ServiceBoundaryRegression
{
    private static nint _restoreDesktop;
    internal static int Run()
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true") return 5;
        using var watchdog = new System.Threading.Timer(_ =>
        {
            nint original = Volatile.Read(ref _restoreDesktop);
            if (original != 0) SwitchDesktop(original);
            Environment.Exit(1);
        }, null,
            TimeSpan.FromSeconds(45), Timeout.InfiniteTimeSpan);
        try { RunAsync().GetAwaiter().GetResult(); return 0; }
        catch (Exception error) { Console.Error.WriteLine($"FAIL SYSTEM desktop integration: {error}"); return 1; }
    }
    private sealed record TestWindow(Form Window, Point Text, Point Button);
    private static async Task RunAsync()
    {
        var config = SystemService.ReadConfiguration();
        Require(config.AllowLocalTestPeer, "The production service must reject local-network self-connections.");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(35));
        var token = timeout.Token;
        byte[] key = Convert.FromHexString(File.ReadAllText(SystemService.PairingKeyPath).Trim());
        using var peer = await RemoteInputRegression.Peer.ConnectAsync(key, config.Port, token);
        await peer.SendAsync(new MouseMessage { Type = "ping" }, token);
        var pong = await peer.ReadAsync(token);
        Require(pong.Type == "pong" && pong.ServiceMode == true, "Paired receiver is not the SYSTEM session agent.");
        var status = SystemService.ReadStatus();
        Require(status is not null && status.SessionId == ConsoleSessionProcess.ActiveSession && status.SessionId != 0,
            "Agent did not run in the interactive console session.");
        Console.WriteLine("PASS protected SYSTEM service launches one paired agent in the physical console session");

        nint original = OpenInputDesktop(0, false, 0x181);
        Require(original != 0, "No original desktop for guaranteed restoration.");
        Volatile.Write(ref _restoreDesktop, original);
        string name = "CrossMouse-CI-" + Guid.NewGuid().ToString("N");
        nint desktop = CreateDesktopW(name, 0, 0, 0, 0x10000000, 0);
        if (desktop == 0)
        {
            Volatile.Write(ref _restoreDesktop, 0); CloseDesktop(original);
            throw new Exception("Could not create isolated desktop.");
        }
        var shown = new TaskCompletionSource<TestWindow>(TaskCreationOptions.RunContinuationsAsynchronously);
        var clicked = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var typed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var ended = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                Require(SetThreadDesktop(desktop), "Test form could not attach to its own desktop.");
                using var window = new Form { Text = "CrossMouse isolated input verification", StartPosition = FormStartPosition.Manual,
                    Location = new Point(100, 100), ClientSize = new Size(420, 200), TopMost = true };
                var text = new TextBox { Location = new Point(30, 30), Width = 300 };
                var button = new Button { Text = "Test input", Location = new Point(30, 85), Size = new Size(160, 45) };
                text.TextChanged += (_, _) => { if (text.Text.Equals("a", StringComparison.OrdinalIgnoreCase)) typed.TrySetResult(); };
                button.Click += (_, _) => clicked.TrySetResult();
                window.Controls.Add(text); window.Controls.Add(button);
                window.Shown += (_, _) => shown.TrySetResult(new(window,
                    text.PointToScreen(new Point(40, 12)), button.PointToScreen(new Point(60, 20))));
                Application.Run(window);
                ended.TrySetResult();
            }
            catch (Exception error) { shown.TrySetException(error); ended.TrySetException(error); }
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA); thread.Start();
        TestWindow? target = null;
        string? transfer = null;
        try
        {
            target = await shown.Task.WaitAsync(token);
            Require(SwitchDesktop(desktop), "Could not activate the isolated test desktop.");
            await Task.Delay(350, token);
            transfer = Guid.NewGuid().ToString();
            await peer.SendAsync(new MouseMessage { Type = "prepare", TransferId = transfer }, token);
            var prepared = await peer.ReadAsync(token);
            Require(prepared.Type == "prepared", $"Preparation failed on alternate input desktop: {prepared.Type}/{prepared.Reason}");
            await peer.SendAsync(new MouseMessage { Type = "enter", TransferId = transfer, CenterCursor = true }, token);
            var entered = await peer.ReadAsync(token);
            Require(entered.Type == "entered" && entered.PointerVisible == true && entered.TransferId == transfer,
                $"Service could not acquire the isolated input desktop: {entered.Type}/{entered.Reason}");
            await peer.SendAsync(new MouseMessage { Type = "ping" }, token);
            pong = await peer.ReadAsync(token);
            Require(pong.InputDesktop == name, "Service still reported a stale Default desktop.");
            await MoveClick(peer, transfer, target.Text, token);
            await peer.SendAsync(new MouseMessage { Type = "key", TransferId = transfer, Code = 0, Down = true }, token);
            await peer.SendAsync(new MouseMessage { Type = "key", TransferId = transfer, Code = 0, Down = false }, token);
            await typed.Task.WaitAsync(TimeSpan.FromSeconds(3), token);
            await MoveClick(peer, transfer, target.Button, token);
            await clicked.Task.WaitAsync(TimeSpan.FromSeconds(3), token);
            Console.WriteLine("PASS authenticated pointer, click, and key input on a different interactive desktop");
            await peer.SendAsync(new MouseMessage { Type = "leave", TransferId = transfer }, token);
            transfer = null;
        }
        finally
        {
            if (transfer is not null)
            {
                try { await peer.SendAsync(new MouseMessage { Type = "leave", TransferId = transfer }, token); } catch (Exception) { }
            }
            SwitchDesktop(original);
            target?.Window.BeginInvoke(new Action(() => target.Window.Close()));
            try { await ended.Task.WaitAsync(TimeSpan.FromSeconds(3)); } catch (TimeoutException) { }
            Volatile.Write(ref _restoreDesktop, 0);
            CloseDesktop(original); CloseDesktop(desktop);
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(key);
        }
        await peer.SendAsync(new MouseMessage { Type = "ping" }, token);
        pong = await peer.ReadAsync(token);
        Require(pong.Type == "pong" && pong.InputDesktop != name, "Service did not follow restoration to the original desktop.");
        Console.WriteLine("PASS original desktop restored; same authenticated service connection stays alive");
    }
    private static async Task MoveClick(RemoteInputRegression.Peer peer, string id, Point target, CancellationToken token)
    {
        Require(Native.GetCursorPos(out var cursor), "Could not read test desktop cursor.");
        await peer.SendAsync(new MouseMessage { Type = "move", TransferId = id, Dx = target.X - cursor.X, Dy = target.Y - cursor.Y }, token);
        await peer.SendAsync(new MouseMessage { Type = "button", TransferId = id, Button = 0, Down = true }, token);
        await peer.SendAsync(new MouseMessage { Type = "button", TransferId = id, Button = 0, Down = false }, token);
        await Task.Delay(80, token);
    }
    private static void Require(bool value, string failure) { if (!value) throw new Exception(failure); }
    [DllImport("user32.dll", SetLastError = true)] private static extern nint OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern nint CreateDesktopW(
        string name, nint device, nint mode, uint flags, uint access, nint attributes);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SetThreadDesktop(nint desktop);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SwitchDesktop(nint desktop);
    [DllImport("user32.dll")] private static extern bool CloseDesktop(nint desktop);
}

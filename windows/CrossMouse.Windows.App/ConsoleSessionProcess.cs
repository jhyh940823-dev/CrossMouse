using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace CrossMouse.Windows.App;

/// <summary>Owns only the child it created. Closing the job kills that child.
/// There is no PID-name search/kill, winlogon-token copying, or remote command.</summary>
internal sealed class ConsoleSessionProcess : IDisposable
{
    private nint _process, _job;
    internal uint SessionId { get; }
    internal static uint ActiveSession => WTSGetActiveConsoleSessionId();
    internal bool HasExited => WaitForSingleObject(_process, 0) != 0x102;
    internal uint ExitCode => GetExitCodeProcess(_process, out uint code) ? code : uint.MaxValue;
    private ConsoleSessionProcess(nint process, nint job, uint session)
    { _process = process; _job = job; SessionId = session; }

    internal static ConsoleSessionProcess Start(string executable, uint session)
    {
        if (!System.Security.Principal.WindowsIdentity.GetCurrent().IsSystem ||
            !string.Equals(executable, SystemService.Executable, StringComparison.OrdinalIgnoreCase))
            throw new UnauthorizedAccessException("Only the protected service agent may be launched.");
        if (!OpenProcessToken(GetCurrentProcess(), 0xF01FF, out nint processToken)) throw Error("open-own-token");
        nint token = 0, job = 0;
        ProcessInfo child = default;
        try
        {
            EnablePrivilege(processToken, "SeTcbPrivilege");
            EnablePrivilege(processToken, "SeAssignPrimaryTokenPrivilege");
            EnablePrivilege(processToken, "SeIncreaseQuotaPrivilege");
            if (!DuplicateTokenEx(processToken, 0xF01FF, 0, 2, 1, out token)) throw Error("duplicate-own-token");
            if (!SetTokenInformation(token, 12, ref session, sizeof(uint))) throw Error("set-console-session");
            job = CreateJobObjectW(0, null);
            var limits = new ExtendedLimits { Basic = new BasicLimits { Flags = 0x2000 } }; // KILL_ON_JOB_CLOSE
            if (job == 0 || !SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf<ExtendedLimits>()))
                throw Error("create-agent-job");
            var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>(), Desktop = "winsta0\\default" };
            var command = new StringBuilder($"\"{executable}\" --session-agent");
            if (!CreateProcessAsUserW(token, executable, command, 0, 0, false,
                0x00000004 | 0x08000000, 0, SystemService.InstallDirectory, ref startup, out child))
                throw Error("launch-console-agent");
            if (!AssignProcessToJobObject(job, child.Process)) throw Error("assign-agent-job");
            if (ResumeThread(child.Thread) == uint.MaxValue) throw Error("resume-agent");
            CloseHandle(child.Thread); child.Thread = 0;
            var result = new ConsoleSessionProcess(child.Process, job, session);
            child.Process = 0; job = 0;
            return result;
        }
        finally
        {
            if (child.Process != 0) { TerminateProcess(child.Process, 1); CloseHandle(child.Process); }
            if (child.Thread != 0) CloseHandle(child.Thread);
            if (job != 0) CloseHandle(job);
            if (token != 0) CloseHandle(token);
            CloseHandle(processToken);
        }
    }
    public void Dispose()
    {
        // Service/session stop lets the agent release held input first. The
        // job is still the bounded fallback for a crashed or unresponsive child.
        if (_process != 0) WaitForSingleObject(_process, 1500);
        if (_job != 0) CloseHandle(_job);
        if (_process != 0) { WaitForSingleObject(_process, 3000); CloseHandle(_process); }
        _job = _process = 0;
    }
    private static Win32Exception Error(string stage) => new(Marshal.GetLastWin32Error(), stage);
    private static void EnablePrivilege(nint token, string name)
    {
        if (!LookupPrivilegeValueW(null, name, out var luid)) throw Error("lookup-service-privilege");
        var privilege = new TokenPrivileges { Count = 1, Luid = luid, Attributes = 2 };
        if (!AdjustTokenPrivileges(token, false, ref privilege, 0, 0, 0) || Marshal.GetLastWin32Error() != 0)
            throw Error("enable-service-privilege");
    }
    [StructLayout(LayoutKind.Sequential)] private struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] private struct TokenPrivileges { public uint Count; public Luid Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct StartupInfo
    { public int Size; public string? Reserved, Desktop, Title; public uint X, Y, Width, Height, XChars, YChars, Fill, Flags;
      public ushort Show, ReservedSize; public nint ReservedBytes, In, Out, Error; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo { public nint Process, Thread; public uint ProcessId, ThreadId; }
    [StructLayout(LayoutKind.Sequential)] private struct BasicLimits
    { public long PerProcess, PerJob; public uint Flags; public nuint MinimumWorkingSet, MaximumWorkingSet;
      public uint ActiveProcessLimit; public nuint Affinity; public uint Priority, Scheduling; }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits
    { public BasicLimits Basic; public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
      public nuint ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
    [DllImport("kernel32.dll")] private static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll")] private static extern nint GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(nint handle);
    [DllImport("kernel32.dll")] private static extern bool GetExitCodeProcess(nint process, out uint code);
    [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(nint handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(nint process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(nint thread);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern nint CreateJobObjectW(nint attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(nint job, int kind,
        ref ExtendedLimits info, int size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(nint job, nint process);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(nint process, uint access, out nint token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool DuplicateTokenEx(nint existing, uint access,
        nint attributes, int level, int type, out nint token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SetTokenInformation(nint token, int kind, ref uint session, int size);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool LookupPrivilegeValueW(string? system,
        string name, out Luid luid);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool AdjustTokenPrivileges(nint token,
        [MarshalAs(UnmanagedType.Bool)] bool disableAll, ref TokenPrivileges privileges, int length, nint previous, nint returnedLength);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CreateProcessAsUserW(
        nint token, string application, StringBuilder command, nint processAttributes, nint threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inherit, uint flags, nint environment, string currentDirectory,
        ref StartupInfo startup, out ProcessInfo process);
}

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

// Temporary CI diagnosis, never invoked on a user's desktop. It only requests
// handles the existing token already has and emits zero-displacement mouse moves
// on the unique isolated test desktop. No ACL, policy or token changes.
internal static class DesktopPermissionProbe
{
    private static readonly HashSet<string> Completed = [];
    internal static void Observe()
    {
        if (!WindowsIdentity.GetCurrent().IsSystem) return;
        var name = InputDesktopAccess.CurrentName();
        if (name is null || !name.StartsWith("CrossMouse-CI-", StringComparison.Ordinal)) return;
        if (!SystemService.ReadConfiguration().AllowLocalTestPeer) return;
        lock (Completed) { if (!Completed.Add(name)) return; }
        var results = new List<object>();
        nint original = GetThreadDesktop(GetCurrentThreadId());
        try
        {
            foreach (uint access in new uint[] { 0x81, 0xA1, 0x181, 0x1FF, 0x02000000 })
            {
                nint desktop = OpenInputDesktop(0, false, access);
                if (desktop == 0) { results.Add(new { access, stage = "open", error = Marshal.GetLastWin32Error() }); continue; }
                try
                {
                    if (!SetThreadDesktop(desktop)) { results.Add(new { access, stage = "bind", error = Marshal.GetLastWin32Error() }); continue; }
                    var input = new Input { Type = 0, Mouse = new Mouse { Flags = 1 } };
                    uint sent = SendInput(1, [input], Marshal.SizeOf<Input>());
                    int error = Marshal.GetLastWin32Error();
                    bool queried = GetUserObjectInformationInt(desktop, 6, out int isInput, sizeof(int), out _);
                    results.Add(new { access, sent, error, session = Process.GetCurrentProcess().SessionId,
                        station = Name(GetProcessWindowStation()), own = Name(GetThreadDesktop(GetCurrentThreadId())),
                        input = InputDesktopAccess.CurrentName(), isInput = queried ? isInput : -1 });
                }
                finally { SetThreadDesktop(original); CloseDesktop(desktop); }
            }
            File.WriteAllText(Path.Combine(SystemService.DataDirectory, "desktop-permissions.json"), JsonSerializer.Serialize(results));
        }
        finally { SetThreadDesktop(original); }
    }
    private static string Name(nint value)
    {
        var name = new StringBuilder(256);
        return GetUserObjectInformationW(value, 2, name, 512, out _) ? name.ToString() : "query-denied";
    }
    [StructLayout(LayoutKind.Sequential)] private struct Mouse { public int X, Y; public uint Data, Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct Input { public uint Type; public Mouse Mouse; }
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, [In] Input[] input, int size);
    [DllImport("user32.dll", SetLastError = true)] private static extern nint OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SetThreadDesktop(nint desktop);
    [DllImport("user32.dll")] private static extern bool CloseDesktop(nint desktop);
    [DllImport("user32.dll")] private static extern nint GetThreadDesktop(uint thread);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern nint GetProcessWindowStation();
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool GetUserObjectInformationW(nint value,
        int index, StringBuilder output, int length, out uint required);
    [DllImport("user32.dll", EntryPoint = "GetUserObjectInformationW", SetLastError = true)] private static extern bool GetUserObjectInformationInt(nint value,
        int index, out int output, int length, out uint required);
}

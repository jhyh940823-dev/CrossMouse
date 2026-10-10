using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace CrossMouse.Windows;

/// <summary>
/// Bind only the CALLING thread to the OS-selected input desktop. Never calls
/// SwitchDesktop, changes a DACL, disables UAC, or moves a visible UI thread.
/// The service's session agent has authority to open Winlogon; a normal user
/// process reports AccessDenied instead of pretending injection succeeded.
/// </summary>
internal sealed class InputDesktopAccess : IDisposable
{
    private nint _owned;
    private readonly nint _previous;
    private readonly bool _changed;
    internal string Name { get; }
    private InputDesktopAccess(nint owned, nint previous, bool changed, string name)
    { _owned = owned; _previous = previous; _changed = changed; Name = name; }

    internal static InputDesktopAccess Enter(bool createsWindow = false)
    {
        uint access = 0x0001 | 0x0080; // READOBJECTS | WRITEOBJECTS
        if (createsWindow) access |= 0x0002; // CREATEWINDOW only for the pointer surface
        nint desktop = OpenInputDesktop(0, false, access);
        if (desktop == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "input-desktop-access-denied");
        try
        {
            nint previous = GetThreadDesktop(GetCurrentThreadId());
            string name = ReadName(desktop);
            bool changed = !string.Equals(name, ReadName(previous), StringComparison.Ordinal);
            if (changed && !SetThreadDesktop(desktop))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "input-desktop-thread-bind-failed");
            return new(desktop, previous, changed, name);
        }
        catch { CloseDesktop(desktop); throw; }
    }

    internal static string? CurrentName()
    {
        nint desktop = OpenInputDesktop(0, false, 0x0001);
        if (desktop == 0) return null;
        try { return ReadName(desktop); }
        catch (Win32Exception) { return null; }
        finally { CloseDesktop(desktop); }
    }
    private static string ReadName(nint desktop)
    {
        var name = new StringBuilder(256);
        if (!GetUserObjectInformationW(desktop, 2, name, name.Capacity * 2, out _))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "input-desktop-name-failed");
        return name.ToString();
    }
    public void Dispose()
    {
        nint owned = Interlocked.Exchange(ref _owned, 0);
        if (owned == 0) return;
        // Pointer surfaces dispose their windows BEFORE this lease. Input
        // workers create no windows/hooks, so they can always restore a desktop.
        if (_changed) SetThreadDesktop(_previous);
        CloseDesktop(owned);
    }
    [DllImport("user32.dll", SetLastError = true)] private static extern nint OpenInputDesktop(uint flags,
        [MarshalAs(UnmanagedType.Bool)] bool inherit, uint desiredAccess);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SetThreadDesktop(nint desktop);
    [DllImport("user32.dll")] private static extern bool CloseDesktop(nint desktop);
    [DllImport("user32.dll")] private static extern nint GetThreadDesktop(uint id);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool
        GetUserObjectInformationW(nint handle, int index, StringBuilder value, int length, out uint required);
}

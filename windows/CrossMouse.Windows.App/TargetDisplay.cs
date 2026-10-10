using System.Runtime.InteropServices;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

/// Resolves the actual Philips display, not the bounding box of all Windows
/// monitors. Physical-monitor handles are owned and destroyed per query.
internal sealed record TargetDisplay(nint Handle, Native.DesktopRectangle Bounds, string Name)
{
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MonitorInfo { public uint Size; public Rect Monitor, Work; public uint Flags; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Physical { public nint Handle; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Description; }
    private delegate bool MonitorEnum(nint monitor, nint dc, nint rect, nint data);
    [DllImport("user32.dll")] private static extern bool EnumDisplayMonitors(nint dc, nint clip, MonitorEnum callback, nint data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern bool GetMonitorInfoW(nint monitor, ref MonitorInfo info);
    [DllImport("dxva2.dll")] private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(nint monitor, out uint count);
    [DllImport("dxva2.dll", CharSet=CharSet.Unicode)] private static extern bool GetPhysicalMonitorsFromHMONITOR(nint monitor, uint count, [Out] Physical[] monitors);
    [DllImport("dxva2.dll")] private static extern bool DestroyPhysicalMonitors(uint count, [In] Physical[] monitors);
    [DllImport("dxva2.dll")] private static extern bool GetVCPFeatureAndVCPFeatureReply(nint monitor, byte code, out uint type, out uint current, out uint maximum);

    internal static TargetDisplay Resolve()
    {
        var found = new List<TargetDisplay>();
        MonitorEnum callback = (handle, _, _, _) =>
        {
            var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>() };
            if (GetMonitorInfoW(handle, ref info) && info.Monitor.R > info.Monitor.L && info.Monitor.B > info.Monitor.T)
            {
                var physical = ReadPhysical(handle);
                try
                {
                    found.Add(new TargetDisplay(handle, new Native.DesktopRectangle(info.Monitor.L,
                        info.Monitor.T, info.Monitor.R-info.Monitor.L, info.Monitor.B-info.Monitor.T),
                        string.Join(" / ", physical.Select(x=>x.Description))));
                }
                finally { if (physical.Length > 0) DestroyPhysicalMonitors((uint)physical.Length, physical); }
            }
            return true;
        };
        if (!EnumDisplayMonitors(0, 0, callback, 0)) throw new IOException("display-enumeration-failed");
        var matches = found.Where(x => x.Name.Contains("271E1", StringComparison.OrdinalIgnoreCase)).ToArray();
        if (matches.Length == 1) return matches[0];
        if (matches.Length == 0 && found.Count == 1) return found[0];
        throw new IOException("target-display-ambiguous");
    }

    /// null means unsupported, never "HDMI confirmed". Non-null wrong source
    /// keeps preparation pending rather than guessing from an elapsed delay.
    internal uint? InputSource()
    {
        var physical = ReadPhysical(Handle);
        try
        {
            foreach (var monitor in physical)
                if (GetVCPFeatureAndVCPFeatureReply(monitor.Handle, 0x60, out _, out uint value, out _) && value > 0)
                    return value;
            return null;
        }
        finally { if (physical.Length > 0) DestroyPhysicalMonitors((uint)physical.Length, physical); }
    }
    private static Physical[] ReadPhysical(nint handle)
    {
        if (!GetNumberOfPhysicalMonitorsFromHMONITOR(handle, out uint count) || count is 0 or > 32) return [];
        var monitors = new Physical[count];
        return GetPhysicalMonitorsFromHMONITOR(handle, count, monitors) ? monitors : [];
    }
}

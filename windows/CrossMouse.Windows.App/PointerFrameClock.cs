using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CrossMouse.Windows.App;

/// <summary>
/// A sleeping render worker, not a Forms WM_TIMER or a ThreadPool timer. The
/// cursor calculation and optional pointer surface share this clock. Does not
/// alter process power settings, Windows mouse settings, or global resolution.
/// </summary>
internal sealed class PointerFrameClock : WaitHandle
{
    internal const int IntervalMilliseconds = 8;
    internal bool IsHighResolution { get; }

    internal PointerFrameClock()
    {
        const uint access = 0x00100002; // SYNCHRONIZE | TIMER_MODIFY_STATE
        var handle = CreateWaitableTimerExW(0, null, 0x00000002, access);
        IsHighResolution = !handle.IsInvalid;
        if (handle.IsInvalid)
        {
            handle.Dispose();
            // Older Windows may not support HIGH_RESOLUTION. Fall back without
            // crashing input sharing; the diagnostic identifies this explicitly.
            handle = CreateWaitableTimerExW(0, null, 0, access);
        }
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, "Could not create cursor frame clock.");
        }
        SafeWaitHandle = handle;
        long due = -IntervalMilliseconds * 10_000L; // relative 100ns units
        if (!SetWaitableTimer(handle, ref due, IntervalMilliseconds, 0, 0, false))
        {
            int error = Marshal.GetLastWin32Error();
            Dispose();
            throw new Win32Exception(error, "Could not start cursor frame clock.");
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeWaitHandle CreateWaitableTimerExW(
        nint attributes, string? name, uint flags, uint access);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWaitableTimer(SafeWaitHandle timer, ref long due,
        int period, nint completionRoutine, nint argument, [MarshalAs(UnmanagedType.Bool)] bool resume);
}

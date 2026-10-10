using System.Diagnostics;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

/// <summary>
/// Windows CI only: simulates the cursor relocation that can accompany a
/// monitor input/desktop change, without touching monitor inputs or settings.
/// Being at the left boundary without a remote leftward move must NOT send
/// the user back to Mac. Runs the real injector and smoothing path.
/// </summary>
internal static class AutomaticEntryRegression
{
    internal static int Run()
    {
        if (!Native.GetCursorPos(out var original)) return 1;
        try
        {
            CheckCenteredEntry();
            foreach (bool smooth in new[] { false, true }) CheckIdleEntry(smooth);
            Console.WriteLine("PASS stationary entry, external cursor relocation, intentional left return");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"FAIL automatic entry: {error}");
            return 1;
        }
        finally { Native.SetCursorPos(original.X, original.Y); }
    }

    private static void CheckCenteredEntry()
    {
        var injector = new InputInjector(smoothMotion: true);
        try
        {
            injector.Apply(new MouseMessage { Type = "enter", FractionY = 0, CenterCursor = true });
            Thread.Sleep(100); // Let Windows consume the entry mouse-move event.
            var desktop = Native.Desktop();
            if (!injector.IsRemotelyActive || !Native.GetCursorPos(out var pointer))
                throw new Exception("Centered automatic entry was not accepted.");
            if (Math.Abs(pointer.X - (desktop.Left + desktop.Width / 2)) > 1 ||
                Math.Abs(pointer.Y - (desktop.Top + desktop.Height / 2)) > 1)
                throw new Exception("Automatic entry left the cursor at the hot corner, not the center.");
            var info = new CursorInfo { Size = System.Runtime.InteropServices.Marshal.SizeOf<CursorInfo>() };
            if (!GetCursorInfo(ref info) || (info.Flags & 1) == 0)
                throw new Exception("Windows CI cursor not visible after entry pointer refresh.");
            if (injector.ReachedLeftEdge()) throw new Exception("Centered entry immediately returned.");
            Console.WriteLine("PASS automatic entry cursor is centered and visible on Windows runner");
        }
        finally { injector.ReleaseAll(); }
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct CursorInfo
    {
        internal int Size;
        internal uint Flags;
        internal nint Cursor;
        internal Native.Point Position;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool GetCursorInfo(ref CursorInfo info);

    private static void CheckIdleEntry(bool smooth)
    {
        var injector = new InputInjector(smoothMotion: smooth);
        try
        {
            injector.Apply(new MouseMessage { Type = "enter", FractionY = 0 });
            if (!injector.IsRemotelyActive) throw new Exception("Entry failed.");
            var desktop = Native.Desktop();
            if (!Native.SetCursorPos(desktop.Left, desktop.Top + desktop.Height / 2))
                throw new Exception("Could not simulate desktop cursor relocation.");

            // No remote input at all. Both a 0ms and a later idle poll must
            // keep Windows active; delaying the old coordinate-only test by
            // a fixed grace period is not an adequate fix.
            var idle = Stopwatch.StartNew();
            do
            {
                injector.Tick();
                if (injector.ReachedLeftEdge() || !injector.IsRemotelyActive)
                    throw new Exception($"Stationary cursor bounced to Mac (smooth={smooth}, {idle.ElapsedMilliseconds}ms).");
                Thread.Sleep(8);
            } while (idle.Elapsed < TimeSpan.FromSeconds(3));

            injector.Apply(new MouseMessage { Type = "move", Dx = 0, Dy = 5 });
            for (int i = 0; i < 12; i++)
            {
                injector.Tick();
                if (injector.ReachedLeftEdge()) throw new Exception("Vertical movement triggered return.");
            }
            // A real leftward push at the boundary must still return once.
            injector.Apply(new MouseMessage { Type = "move", Dx = -12, Dy = 0 });
            bool returned = false;
            for (int i = 0; i < 20 && !returned; i++)
            {
                injector.Tick();
                returned = injector.ReachedLeftEdge();
                Thread.Sleep(8);
            }
            if (!returned || injector.IsRemotelyActive || injector.ReachedLeftEdge())
                throw new Exception("Intentional left push did not return exactly once.");

            injector.Apply(new MouseMessage { Type = "enter", FractionY = 0.5 });
            if (!injector.IsRemotelyActive || injector.ReachedLeftEdge())
                throw new Exception("Old pending motion/return survived re-entry.");
            Console.WriteLine($"PASS idle entry and deliberate return (smooth={smooth})");
        }
        finally { injector.ReleaseAll(); }
    }
}

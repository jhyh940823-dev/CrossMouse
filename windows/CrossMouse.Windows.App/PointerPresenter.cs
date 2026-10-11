using System.Drawing;
using System.Runtime.InteropServices;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

/// The remote session owns its pointer surface for the entire focus lease.
/// CURSOR_SHOWING and MousePresent describe OS state, not proof that the paired
/// PC's hardware cursor is visible. Never switch our only guaranteed drawing
/// path off on those flags. Native shape/hotspot still come from Windows; no
/// ShowCursor counters, cursor scheme or other process state is modified.
internal sealed class PointerPresenter : IDisposable
{
    private readonly object _sync = new();
    private readonly Func<bool> _active;
    private readonly Action? _observedFrame;
    private PointerSurfaceThread? _thread;
    private string? _desktop;
    private bool _disposed;
    internal PointerPresenter(Func<bool> active, Action? observedFrameForTest = null)
    { _active = active; _observedFrame = observedFrameForTest; }
    internal string? Failure { get { lock (_sync) return _thread?.Failure; } }
    internal string State
    {
        get
        {
            lock (_sync)
                return _thread?.Failure ?? (_thread?.IsPresented == true
                    ? "surface:" + _desktop + ";stack-repairs:" + _thread.StackingRepairs : "not-presented");
        }
    }
    private PointerSurfaceThread? Current(bool retryFailed = false)
    {
        string? desktop = InputDesktopAccess.CurrentName();
        lock (_sync)
        {
            if (_disposed) return null;
            if (desktop != _desktop || (retryFailed && _thread?.Failure is not null))
            { _thread?.Dispose(); _thread = null; _desktop = desktop; }
            if (desktop is null) return null;
            return _thread ??= new PointerSurfaceThread(_active, _observedFrame, desktop);
        }
    }
    internal bool RequestRefresh() => Current()?.RequestRefresh() ?? false;
    // A new acquisition may retry a failed surface; render ticks never create
    // unbounded replacement threads on a persistently inaccessible desktop.
    internal Task<bool> VerifyAsync(CancellationToken token) => Current(retryFailed: true)?.VerifyAsync(token) ?? Task.FromResult(false);
    public void Dispose()
    { lock (_sync) { _disposed = true; _thread?.Dispose(); _thread = null; } }
}

/// A window belongs to exactly one desktop for its entire lifetime. Replace
/// its thread when Windows changes desktop; never try to rebind an existing Form.
internal sealed class PointerSurfaceThread : IDisposable
{
    private readonly TaskCompletionSource<Surface> _surface = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Func<bool> _active;
    private int _disposed;
    private int _refreshQueued;
    private string? _failure;
    private int _presented;
    private int _stackingRepairs;
    internal string? Failure => Volatile.Read(ref _failure);
    internal int StackingRepairs => Volatile.Read(ref _stackingRepairs);
    internal bool IsPresented => Volatile.Read(ref _presented) != 0 && Volatile.Read(ref _disposed) == 0;
    internal PointerSurfaceThread(Func<bool> active,
        Action? observedFrameForTest, string expectedDesktop)
    {
        _active = active;
        var thread = new Thread(() =>
        {
            try
            {
                using var desktop = InputDesktopAccess.Enter(createsWindow: true);
                if (desktop.Name != expectedDesktop) throw new IOException("pointer-desktop-changed-before-create");
                using var surface = new Surface(_active, observedFrameForTest);
                _ = surface.Handle;
                _surface.TrySetResult(surface);
                Application.Run(new ApplicationContext());
            }
            catch (Exception error)
            {
                Volatile.Write(ref _failure, "pointer-thread:" + error.GetType().Name);
                _surface.TrySetException(error);
            }
        }) { IsBackground = true, Name = "CrossMouse.PointerPresentation" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
    }

    /// <summary>
    /// Called AFTER the receiver applies this frame's movement. Queue at most
    /// one UI callback and read the latest cursor when it runs; never accumulate
    /// old positions. In particular, the input thread never waits for painting.
    /// </summary>
    internal bool RequestRefresh()
    {
        if (Volatile.Read(ref _disposed) != 0 || !_surface.Task.IsCompletedSuccessfully ||
            Interlocked.CompareExchange(ref _refreshQueued, 1, 0) != 0) return false;
        try
        {
            Surface surface = _surface.Task.Result;
            surface.BeginInvoke(new Action(() =>
            {
                try
                {
                    if (Volatile.Read(ref _disposed) == 0 && !surface.IsDisposed)
                        Refresh(surface);
                }
                finally { Volatile.Write(ref _refreshQueued, 0); }
            }));
            return true;
        }
        catch (InvalidOperationException)
        {
            Volatile.Write(ref _refreshQueued, 0);
            return false; // presentation thread is already closing
        }
    }
    internal async Task<bool> VerifyAsync(CancellationToken token)
    {
        Surface surface = await _surface.Task.WaitAsync(token).ConfigureAwait(false);
        var done = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        surface.BeginInvoke(new Action(() =>
        {
            try { done.TrySetResult(Refresh(surface)); }
            catch (Exception error) { done.TrySetException(error); }
        }));
        return await done.Task.WaitAsync(token).ConfigureAwait(false);
    }
    private bool Refresh(Surface surface)
    {
        try
        {
            bool visible = surface.RefreshPointer();
            Volatile.Write(ref _presented, visible ? 1 : 0);
            Volatile.Write(ref _stackingRepairs, surface.StackingRepairs);
            Volatile.Write(ref _failure, _active() && !visible
                ? surface.Failure ?? "pointer-presentation-failed" : null);
            return visible;
        }
        catch (Exception error) when (error is ArgumentException or ExternalException or InvalidOperationException)
        {
            // A bad/replaced native cursor resource must not kill this message
            // loop and leave the receiver saying it owns an invisible pointer.
            Volatile.Write(ref _failure, "pointer-presentation:" + error.GetType().Name);
            Volatile.Write(ref _presented, 0);
            surface.Hide();
            return false;
        }
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        _ = _surface.Task.ContinueWith(task =>
        {
            if (task.Status == TaskStatus.RanToCompletion && !task.Result.IsDisposed)
            {
                try { task.Result.BeginInvoke(new Action(() => { task.Result.Close(); Application.ExitThread(); })); }
                catch (InvalidOperationException) { /* owning thread already exited */ }
            }
        }, TaskScheduler.Default);
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct CursorInfo { public int Size; public uint Flags; public nint Cursor; public Native.Point Position; }
    [DllImport("user32.dll")] private static extern bool GetCursorInfo(ref CursorInfo info);

    private sealed class Surface : Form
    {
        private readonly Func<bool> _active;
        private LayeredCursorImage? _image;
        private nint _cursorHandle;
        private readonly Action? _observedFrameForTest;
        internal int StackingRepairs { get; private set; }
        internal string? Failure { get; private set; }
        internal Surface(Func<bool> active, Action? observedFrameForTest)
        {
            _active = active;
            _observedFrameForTest = observedFrameForTest;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false; TopMost = true;
            AutoScaleMode = AutoScaleMode.None; // Win32 pointer coordinates are device pixels
        }
        protected override bool ShowWithoutActivation => true;
        protected override CreateParams CreateParams
        {
            get { var cp = base.CreateParams; cp.ExStyle |= 0x00080000 | 0x00000020 | 0x00000080 | 0x08000000; return cp; }
        }
        internal bool RefreshPointer()
        {
            Failure = null;
            if (!_active()) { if (Visible) Hide(); return false; }
            _observedFrameForTest?.Invoke();
            var info = new CursorInfo { Size = Marshal.SizeOf<CursorInfo>() };
            if (!GetCursorInfo(ref info)) { if (Visible) Hide(); return false; }
            bool cursorChanged = _image is null || _cursorHandle != info.Cursor;
            if (cursorChanged)
            {
                _cursorHandle = info.Cursor;
                _image?.Dispose();
                _image = new LayeredCursorImage(CursorRaster.Capture(info.Cursor));
            }
            // Do not yield visual ownership to a native visibility flag when
            // crossing an app/control. A null or transparent glyph is rendered
            // as an owned fallback, using the exact OS position/hotspot.
            Bounds = new Rectangle(info.Position.X - _image!.Raster.HotX, info.Position.Y - _image.Raster.HotY,
                _image.Raster.Width, _image.Raster.Height);
            if (!Visible) Show();
            if (!_image.Present(Handle, info.Position)) { Hide(); return false; }
            // UpdateLayeredWindow can succeed while a later topmost popup
            // covers this HWND. TopMost assigns a GROUP, not permanent first
            // position within that group. Keep stacking as part of the same
            // frame's presentation contract, even for a stationary pointer.
            // The previous tests hid/showed this Form before every sample,
            // inadvertently repairing the z-order themselves.
            if (HasOverlappingWindowAbove())
            {
                if (!SetWindowPos(Handle, new nint(-1), 0, 0, 0, 0,
                    0x0001 | 0x0002 | 0x0010 | 0x0200)) // NOSIZE | NOMOVE | NOACTIVATE | NOOWNERZORDER
                {
                    Failure = "pointer-stacking:" + Marshal.GetLastWin32Error();
                    return false;
                }
                StackingRepairs++;
                if (HasOverlappingWindowAbove())
                {
                    Failure = "pointer-occluded";
                    return false;
                }
            }
            return true;
        }
        private bool HasOverlappingWindowAbove()
        {
            // Read geometry only: no window titles, processes, screenshots or
            // hooks in other applications. Traverse a bounded snapshot; never
            // spin if another application continuously changes the window list.
            const uint previous = 3; // GW_HWNDPREV
            Rectangle footprint = Bounds;
            nint window = GetWindow(Handle, previous);
            for (int inspected = 0; window != 0 && inspected < 256; inspected++)
            {
                if (IsWindowVisible(window) && !IsIconic(window) && GetWindowRect(window, out var rect) &&
                    footprint.IntersectsWith(Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom)))
                {
                    // Cloaked windows retain VISIBLE but are not composed on
                    // this desktop (e.g. a different Windows virtual desktop).
                    int result = DwmGetWindowAttribute(window, 14, out uint cloaked, sizeof(uint));
                    if (result != 0 || cloaked == 0) return true;
                }
                nint next = GetWindow(window, previous);
                if (next == window) return true;
                window = next;
            }
            return window != 0;
        }
        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x84) { message.Result = -1; return; } // HTTRANSPARENT
            if (message.Msg == 0x21) { message.Result = 3; return; } // MA_NOACTIVATE
            base.WndProc(ref message);
        }
        protected override void OnPaintBackground(PaintEventArgs e) { }
        protected override void OnPaint(PaintEventArgs e) { }
        protected override void Dispose(bool disposing)
        { if (disposing) { _image?.Dispose(); _image = null; } base.Dispose(disposing); }

        [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] private static extern nint GetWindow(nint window, uint command);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(nint window, out Rect rect);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
        [DllImport("user32.dll")] private static extern bool IsIconic(nint window);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool SetWindowPos(nint window, nint after,
            int x, int y, int width, int height, uint flags);
        [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint window,
            uint attribute, out uint value, int size);
    }
}

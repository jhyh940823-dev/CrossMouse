using System.Drawing;
using System.Runtime.InteropServices;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

/// Presentation belongs to the remote-input session, not to whether Windows
/// has a physical mouse plugged in. Never changes ShowCursor counters or OS
/// mouse settings. A click-through, non-activating pointer surface is used only
/// when the native pointer is not shown. It runs independently of the settings UI.
internal sealed class PointerPresenter : IDisposable
{
    private readonly object _sync = new();
    private readonly Func<bool> _active;
    private readonly bool _simulateHidden;
    private readonly Action? _observedFrame;
    private PointerSurfaceThread? _thread;
    private string? _desktop;
    private bool _disposed;
    internal PointerPresenter(Func<bool> active, bool simulateHiddenNativePointerForTest = false,
        Action? observedFrameForTest = null)
    { _active = active; _simulateHidden = simulateHiddenNativePointerForTest; _observedFrame = observedFrameForTest; }
    private PointerSurfaceThread? Current()
    {
        string? desktop = InputDesktopAccess.CurrentName();
        lock (_sync)
        {
            if (_disposed) return null;
            if (desktop != _desktop)
            { _thread?.Dispose(); _thread = null; _desktop = desktop; }
            if (desktop is null) return null;
            return _thread ??= new PointerSurfaceThread(_active, _simulateHidden, _observedFrame, desktop);
        }
    }
    internal bool RequestRefresh() => Current()?.RequestRefresh() ?? false;
    internal Task<bool> VerifyAsync(CancellationToken token) => Current()?.VerifyAsync(token) ?? Task.FromResult(false);
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
    internal PointerSurfaceThread(Func<bool> active, bool simulateHiddenNativePointerForTest,
        Action? observedFrameForTest, string expectedDesktop)
    {
        _active = active;
        var thread = new Thread(() =>
        {
            try
            {
                using var desktop = InputDesktopAccess.Enter(createsWindow: true);
                if (desktop.Name != expectedDesktop) throw new IOException("pointer-desktop-changed-before-create");
                using var surface = new Surface(_active, simulateHiddenNativePointerForTest, observedFrameForTest);
                _ = surface.Handle;
                _surface.TrySetResult(surface);
                Application.Run(new ApplicationContext());
            }
            catch (Exception error) { _surface.TrySetException(error); }
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
                        surface.RefreshPointer();
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
            try { done.TrySetResult(surface.RefreshPointer()); }
            catch (Exception error) { done.TrySetException(error); }
        }));
        return await done.Task.WaitAsync(token).ConfigureAwait(false);
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
        private readonly bool _simulateHidden;
        private readonly Action? _observedFrameForTest;
        internal Surface(Func<bool> active, bool simulateHidden, Action? observedFrameForTest)
        {
            _active = active;
            _simulateHidden = simulateHidden;
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
            // CURSOR_SHOWING is only an OS flag. A null/transparent resource
            // must not make us hide the only visible remote pointing surface.
            if (!_simulateHidden && SystemInformation.MousePresent && (info.Flags & 1) != 0 && !_image!.Raster.UsedFallback)
            {
                if (Visible) Hide();
                return true;
            }
            Bounds = new Rectangle(info.Position.X - _image!.Raster.HotX, info.Position.Y - _image.Raster.HotY,
                _image.Raster.Width, _image.Raster.Height);
            if (!Visible) Show();
            if (!_image.Present(Handle, info.Position)) { Hide(); return false; }
            return true;
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
    }
}

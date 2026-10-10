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
    private readonly TaskCompletionSource<Surface> _surface = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Func<bool> _active;
    private int _disposed;
    internal PointerPresenter(Func<bool> active, bool simulateHiddenNativePointerForTest = false)
    {
        _active = active;
        var thread = new Thread(() =>
        {
            try
            {
                using var surface = new Surface(_active, simulateHiddenNativePointerForTest);
                _ = surface.Handle;
                _surface.TrySetResult(surface);
                Application.Run(new ApplicationContext());
            }
            catch (Exception error) { _surface.TrySetException(error); }
        }) { IsBackground = true, Name = "CrossMouse.PointerPresentation" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
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
        private readonly System.Windows.Forms.Timer _timer = new() { Interval = 8 };
        private Cursor _pointer = Cursors.Default;
        private nint _cursorHandle;
        private readonly bool _simulateHidden;
        internal Surface(Func<bool> active, bool simulateHidden)
        {
            _active = active;
            _simulateHidden = simulateHidden;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false; TopMost = true;
            BackColor = Color.Magenta; TransparencyKey = Color.Magenta;
            DoubleBuffered = true;
            _timer.Tick += (_, _) => RefreshPointer();
            _timer.Start();
        }
        protected override bool ShowWithoutActivation => true;
        protected override CreateParams CreateParams
        {
            get { var cp = base.CreateParams; cp.ExStyle |= 0x00000020 | 0x00000080 | 0x08000000; return cp; }
        }
        internal bool RefreshPointer()
        {
            if (!_active()) { if (Visible) Hide(); return false; }
            var info = new CursorInfo { Size = Marshal.SizeOf<CursorInfo>() };
            if (!GetCursorInfo(ref info)) { if (Visible) Hide(); return false; }
            if (!_simulateHidden && (info.Flags & 1) != 0) { if (Visible) Hide(); return true; }
            if (_cursorHandle != info.Cursor)
            {
                _cursorHandle = info.Cursor;
                _pointer = info.Cursor != 0 ? new Cursor(info.Cursor) : Cursors.Default;
            }
            var hotspot = _pointer.HotSpot;
            Bounds = new Rectangle(info.Position.X - hotspot.X, info.Position.Y - hotspot.Y,
                _pointer.Size.Width, _pointer.Size.Height);
            if (!Visible) Show();
            Invalidate(); Update();
            return Visible;
        }
        protected override void OnPaint(PaintEventArgs e) { _pointer.Draw(e.Graphics, ClientRectangle); }
        protected override void Dispose(bool disposing) { if (disposing) _timer.Dispose(); base.Dispose(disposing); }
    }
}

using System.Runtime.InteropServices;
using System.Diagnostics;

namespace CrossMouse.Windows;

/// <summary>
/// Inject only after an authenticated connection explicitly enters Windows.
/// Mouse return detection uses the left edge of the Windows virtual desktop;
/// the intended MVP setup has one Windows monitor (the right-hand Philips).
/// </summary>
internal sealed class InputInjector
{
    private readonly object _sync = new();
    private readonly HashSet<int> _downKeys = [];
    private readonly HashSet<int> _downButtons = [];
    private readonly MotionSmoother _motion = new();
    private bool _smoothMotion;
    private int _recentMovePackets;
    private int _recentGapsOver25Ms;
    private int _recentMaxGapMs;
    private long _lastMovementTimestamp;
    private bool _remoteActive;

    internal readonly record struct MotionGapStats(
        int MovePackets, int GapsOver25Ms, int MaxGapMs);

    public InputInjector(bool smoothMotion = false)
    {
        _smoothMotion = smoothMotion;
    }

    public bool IsRemotelyActive
    {
        get { lock (_sync) return _remoteActive; }
    }

    /// <summary>
    /// Compare the smooth render path with the original immediate path.
    /// Switching off drains outstanding motion before changing modes.
    /// </summary>
    public void SetSmoothingEnabled(bool enabled)
    {
        lock (_sync)
        {
            if (_smoothMotion && !enabled && _remoteActive)
            {
                var remaining = _motion.Drain();
                MoveCore(remaining.Dx, remaining.Dy);
            }
            _motion.Reset();
            _smoothMotion = enabled;
        }
    }

    public MotionGapStats TakeMotionGapStats()
    {
        lock (_sync)
        {
            var stats = new MotionGapStats(
                _recentMovePackets, _recentGapsOver25Ms, _recentMaxGapMs);
            _recentMovePackets = 0;
            _recentGapsOver25Ms = 0;
            _recentMaxGapMs = 0;
            _lastMovementTimestamp = 0;
            return stats;
        }
    }

    /// <summary>
    /// Call on a background timer around every 8 ms while authenticated.
    /// Rendering and input processing are locked together so click positions
    /// always include all preceding mouse movement.
    /// </summary>
    public void Tick()
    {
        lock (_sync)
        {
            if (!_remoteActive || !_smoothMotion || !_motion.HasPending) return;
            var step = _motion.Step();
            MoveCore(step.Dx, step.Dy);
        }
    }

    public void Apply(MouseMessage message)
    {
        lock (_sync)
        {
            if (message.Type == "enter")
            {
                ReleaseAllCore();
                _motion.Reset();
                _lastMovementTimestamp = 0;
                var desktop = Native.Desktop();
                var fraction = Math.Clamp(message.FractionY ?? 0.5, 0.0, 1.0);
                int x = desktop.Left + Math.Min(64, Math.Max(8, desktop.Width / 8));
                int y = desktop.Top + (int)Math.Round((desktop.Height - 1) * fraction);
                Native.SetCursorPos(x, y);
                _remoteActive = true;
                return;
            }
            if (message.Type == "leave")
            {
                _remoteActive = false;
                _motion.Reset();
                ReleaseAllCore();
                return;
            }
            if (!_remoteActive) return;

            switch (message.Type)
            {
                case "move":
                    int dx = Math.Clamp(message.Dx ?? 0, -2048, 2048);
                    int dy = Math.Clamp(message.Dy ?? 0, -2048, 2048);
                    RecordMovementGap();
                    if (_smoothMotion) _motion.Add(dx, dy);
                    else MoveCore(dx, dy);
                    break;
                case "button":
                    if (message.Button is int button && message.Down is bool down)
                    {
                        FlushMovementCore();
                        if (down) _downButtons.Add(button);
                        else _downButtons.Remove(button);
                        Native.MouseButton(button, down);
                    }
                    break;
                case "wheel":
                    FlushMovementCore();
                    if (message.Vertical is int vertical && vertical != 0)
                        Native.Scroll(vertical, horizontal: false);
                    if (message.Horizontal is int horizontal && horizontal != 0)
                        Native.Scroll(horizontal, horizontal: true);
                    break;
                case "key":
                    if (message.Code is int key && message.Down is bool pressed &&
                        KeyMapping.TryGet(key, out int scanCode))
                    {
                        FlushMovementCore();
                        if (pressed) _downKeys.Add(key);
                        else _downKeys.Remove(key);
                        Native.Key(scanCode, pressed);
                    }
                    break;
            }
        }
    }

    public bool ReachedLeftEdge()
    {
        lock (_sync)
        {
            if (!_remoteActive || !Native.GetCursorPos(out var point)) return false;
            if (point.X > Native.Desktop().Left + 2) return false;
            _remoteActive = false;
            ReleaseAllCore();
            return true;
        }
    }

    public void ReleaseAll()
    {
        lock (_sync)
        {
            _remoteActive = false;
            _motion.Reset();
            ReleaseAllCore();
        }
    }

    private void RecordMovementGap()
    {
        long now = Stopwatch.GetTimestamp();
        if (_lastMovementTimestamp != 0)
        {
            double gap = Stopwatch.GetElapsedTime(_lastMovementTimestamp, now).TotalMilliseconds;
            // Don't call a deliberate user pause or a different movement
            // gesture a network hitch. Values remain approximate diagnostics.
            if (gap > 25 && gap < 250)
            {
                _recentGapsOver25Ms++;
                _recentMaxGapMs = Math.Max(_recentMaxGapMs, (int)Math.Round(gap));
            }
        }
        _recentMovePackets++;
        _lastMovementTimestamp = now;
    }

    private void FlushMovementCore()
    {
        if (!_smoothMotion || !_motion.HasPending) return;
        var remaining = _motion.Drain();
        MoveCore(remaining.Dx, remaining.Dy);
    }

    private static void MoveCore(int dx, int dy)
    {
        if ((dx == 0 && dy == 0) || !Native.GetCursorPos(out var cursor)) return;
        var desktop = Native.Desktop();
        long x = Math.Clamp((long)cursor.X + dx, desktop.Left, (long)desktop.Right - 1);
        long y = Math.Clamp((long)cursor.Y + dy, desktop.Top, (long)desktop.Bottom - 1);
        Native.SetCursorPos((int)x, (int)y);
    }

    private void ReleaseAllCore()
    {
        foreach (int key in _downKeys)
        {
            if (KeyMapping.TryGet(key, out int scanCode)) Native.Key(scanCode, down: false);
        }
        _downKeys.Clear();
        foreach (int button in _downButtons) Native.MouseButton(button, down: false);
        _downButtons.Clear();
    }
}

internal static class Native
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct Point { public int X; public int Y; }

    internal readonly record struct DesktopRectangle(int Left, int Top, int Width, int Height)
    {
        public int Right => Left + Width;
        public int Bottom => Top + Height;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Union;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MouseInput Mouse;
        [FieldOffset(0)] public KeyboardInput Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int Dx;
        public int Dy;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public nuint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public nuint ExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, [In] Input[] inputs, int size);

    [DllImport("user32.dll")]
    internal static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll")]
    internal static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    internal static extern bool SetProcessDPIAware();

    internal static DesktopRectangle Desktop() => new(
        GetSystemMetrics(76), GetSystemMetrics(77),
        GetSystemMetrics(78), GetSystemMetrics(79)
    );

    internal static void Key(int scanCode, bool down)
    {
        uint flags = 0x0008; // KEYEVENTF_SCANCODE
        if ((scanCode & 0x100) != 0) flags |= 0x0001; // KEYEVENTF_EXTENDEDKEY
        if (!down) flags |= 0x0002; // KEYEVENTF_KEYUP
        Send(new Input
        {
            Type = 1,
            Union = new InputUnion
            {
                Keyboard = new KeyboardInput { ScanCode = (ushort)(scanCode & 0xFF), Flags = flags }
            }
        });
    }

    internal static void MouseButton(int button, bool down)
    {
        uint flag;
        uint extra = 0;
        switch (button)
        {
            case 0: flag = down ? 0x0002u : 0x0004u; break; // Left
            case 1: flag = down ? 0x0008u : 0x0010u; break; // Right
            case 2: flag = down ? 0x0020u : 0x0040u; break; // Middle
            case 3: flag = down ? 0x0080u : 0x0100u; extra = 1; break; // X1
            case 4: flag = down ? 0x0080u : 0x0100u; extra = 2; break; // X2
            default: return;
        }
        Send(new Input
        {
            Type = 0,
            Union = new InputUnion { Mouse = new MouseInput { Flags = flag, MouseData = extra } }
        });
    }

    internal static void Scroll(int ticks, bool horizontal)
    {
        // Windows WHEEL_DELTA is 120 units per conventional detent.
        int delta = Math.Clamp(ticks, -30, 30) * 120;
        Send(new Input
        {
            Type = 0,
            Union = new InputUnion
            {
                Mouse = new MouseInput
                {
                    Flags = horizontal ? 0x01000u : 0x0800u,
                    MouseData = unchecked((uint)delta)
                }
            }
        });
    }

    private static void Send(Input input)
    {
        _ = SendInput(1, [input], Marshal.SizeOf<Input>());
    }
}

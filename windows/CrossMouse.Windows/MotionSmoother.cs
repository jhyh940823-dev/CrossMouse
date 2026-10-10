namespace CrossMouse.Windows;

/// <summary>
/// Source-timed linear playout, not a size-dependent "take 65/80 percent" step.
/// A short bounded timeline separates packet delivery from cursor frame times.
/// It never extrapolates input, conserves accumulated distance, and drains at
/// click/keyboard boundaries. A late burst is re-anchored, not replayed forever.
/// No OS calls, clocks, sleeps, prediction, or background thread live here.
/// </summary>
internal sealed class MotionSmoother
{
    private readonly record struct Sample(double Time, long X, long Y);
    private readonly List<Sample> _samples = [];
    private long _targetX, _targetY, _emittedX, _emittedY;
    private double? _sourceBase;
    private double _localBase, _lastSource, _lastArrival, _lastRender, _virtualClock;
    internal int LateRebases { get; private set; }
    internal int BufferedSamples => _samples.Count;
    public bool HasPending => _samples.Count > 1 || _targetX != _emittedX || _targetY != _emittedY;

    // Deterministic fixed-8ms adapter retained for the existing console fixtures.
    public void Add(int dx, int dy) => AddAt(dx, dy, _virtualClock);
    public (int Dx, int Dy) Step() { _virtualClock += 8; return StepAt(_virtualClock); }

    internal void AddAt(int dx, int dy, double nowMilliseconds, long? sourceMicroseconds = null)
    {
        if ((dx == 0 && dy == 0) || !double.IsFinite(nowMilliseconds)) return;
        double now = Math.Max(_lastRender, nowMilliseconds);
        double source = sourceMicroseconds is >= 0 ? sourceMicroseconds.Value / 1000.0 : now;
        bool wasIdle = !HasPending;
        _targetX = _emittedX + Math.Clamp(_targetX - _emittedX + dx, -32768, 32768);
        _targetY = _emittedY + Math.Clamp(_targetY - _emittedY + dy, -32768, 32768);
        if (wasIdle || _sourceBase is null || source < _lastSource || source - _lastSource > 250 || now - _lastArrival > 250)
        {
            _sourceBase = source; _localBase = now + 16;
            _samples.Clear(); _samples.Add(new(now, _emittedX, _emittedY));
        }
        double due = _localBase + source - _sourceBase.Value;
        if (due < now + 4)
        {
            _localBase += now + 12 - due; due = now + 12;
            LateRebases++;
        }
        if (_samples.Count > 1 && source == _lastSource && now == _lastArrival)
            _samples[^1] = new(_samples[^1].Time, _targetX, _targetY);
        else
        {
            if (_samples.Count == 0) _samples.Add(new(now, _emittedX, _emittedY));
            due = Math.Max(due, _samples[^1].Time + 0.001);
            _samples.Add(new(due, _targetX, _targetY));
        }
        if (_samples.Count > 64 || _samples[^1].Time - now > 48)
        {
            // Bound time AND memory. We preserve the final cumulative position
            // but do not play old packet positions long after the user stopped.
            _samples.Clear(); _samples.Add(new(now, _emittedX, _emittedY));
            _samples.Add(new(now + 16, _targetX, _targetY));
            _sourceBase = source; _localBase = now + 16; LateRebases++;
        }
        _lastSource = source; _lastArrival = now;
    }

    internal (int Dx, int Dy) StepAt(double nowMilliseconds)
    {
        if (!double.IsFinite(nowMilliseconds) || _samples.Count == 0) return (0, 0);
        double now = Math.Max(_lastRender, nowMilliseconds); _lastRender = now;
        while (_samples.Count > 1 && _samples[1].Time <= now) _samples.RemoveAt(0);
        var first = _samples[0]; double x = first.X, y = first.Y;
        if (_samples.Count > 1)
        {
            var next = _samples[1];
            double fraction = Math.Clamp((now - first.Time) / (next.Time - first.Time), 0, 1);
            x += (next.X - first.X) * fraction; y += (next.Y - first.Y) * fraction;
        }
        long ix = (long)Math.Round(x, MidpointRounding.AwayFromZero), iy = (long)Math.Round(y, MidpointRounding.AwayFromZero);
        var result = ((int)(ix - _emittedX), (int)(iy - _emittedY));
        _emittedX = ix; _emittedY = iy;
        return result;
    }
    public (int Dx, int Dy) Drain()
    {
        var remaining = ((int)(_targetX - _emittedX), (int)(_targetY - _emittedY));
        Reset(); return remaining;
    }
    public void Reset()
    {
        _samples.Clear(); _sourceBase = null;
        _targetX = _targetY = _emittedX = _emittedY = 0;
        _localBase = _lastSource = _lastArrival = _lastRender = _virtualClock = 0;
        LateRebases = 0;
    }
}

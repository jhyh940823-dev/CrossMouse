namespace CrossMouse.Windows;

/// <summary>
/// Spreads irregularly arriving, relative mouse deltas over short render ticks
/// without inventing motion. A packet is not a frame: TCP can deliver several
/// packets together or stall and then deliver a burst.
///
/// This class contains no OS calls or timers and can be tested deterministically.
/// Calls must be serialized by its owner.
/// </summary>
internal sealed class MotionSmoother
{
    private int _remainingX;
    private int _remainingY;

    public bool HasPending => _remainingX != 0 || _remainingY != 0;

    public void Add(int dx, int dy)
    {
        // The sender already caps its wire values, but avoid unlimited
        // backlog if a peer floods valid packets faster than we can render.
        _remainingX = (int)Math.Clamp((long)_remainingX + dx, -32768, 32768);
        _remainingY = (int)Math.Clamp((long)_remainingY + dy, -32768, 32768);
    }

    public (int Dx, int Dy) Step()
    {
        return (Advance(ref _remainingX), Advance(ref _remainingY));
    }

    public (int Dx, int Dy) Drain()
    {
        var result = (_remainingX, _remainingY);
        Reset();
        return result;
    }

    public void Reset()
    {
        _remainingX = 0;
        _remainingY = 0;
    }

    private static int Advance(ref int remaining)
    {
        if (remaining == 0) return 0;
        int magnitude = Math.Abs(remaining);
        // Small movements stay responsive. Larger arrivals get distributed
        // over a few ~8 ms ticks rather than becoming one visible jump.
        double fraction = magnitude <= 16 ? 0.80 : 0.65;
        int step = Math.Min(256, Math.Max(1, (int)Math.Ceiling(magnitude * fraction)));
        step = Math.Min(step, magnitude);
        int signedStep = remaining > 0 ? step : -step;
        remaining -= signedStep;
        return signedStep;
    }
}

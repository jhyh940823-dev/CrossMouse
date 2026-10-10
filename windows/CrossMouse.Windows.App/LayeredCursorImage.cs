using System.ComponentModel;
using System.Runtime.InteropServices;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

/// Owned, top-down, premultiplied DIB. ULW_ALPHA, never TransparencyKey.
internal sealed class LayeredCursorImage : IDisposable
{
    private nint _dc, _bitmap, _previous;
    internal CursorRaster Raster { get; }
    internal LayeredCursorImage(CursorRaster raster)
    {
        Raster = raster;
        var header = new BitmapInfo { Size = 40, Width = raster.Width, Height = -raster.Height,
            Planes = 1, Bits = 32 };
        _dc = CreateCompatibleDC(0);
        _bitmap = CreateDIBSection(_dc, ref header, 0, out var bits, 0, 0);
        if (_dc == 0 || _bitmap == 0 || bits == 0) { Dispose(); throw new Win32Exception("Cursor DIB allocation failed."); }
        _previous = SelectObject(_dc, _bitmap);
        Marshal.Copy(raster.Pixels, 0, bits, raster.Pixels.Length);
    }
    internal bool Present(nint window, Native.Point pointer)
    {
        var target = new Native.Point { X = pointer.X - Raster.HotX, Y = pointer.Y - Raster.HotY };
        Native.Point origin = default;
        var size = new Size { Width = Raster.Width, Height = Raster.Height };
        var blend = new Blend { ConstantAlpha = 255, AlphaFormat = 1 };
        return UpdateLayeredWindow(window, 0, ref target, ref size, _dc, ref origin, 0, ref blend, 2);
    }
    public void Dispose()
    {
        if (_dc != 0 && _previous != 0) SelectObject(_dc, _previous);
        if (_bitmap != 0) DeleteObject(_bitmap);
        if (_dc != 0) DeleteDC(_dc);
        _dc = _bitmap = _previous = 0;
    }
    [StructLayout(LayoutKind.Sequential)] private struct BitmapInfo
    { public uint Size; public int Width, Height; public ushort Planes, Bits; public uint Compression, ImageSize;
      public int XPixels, YPixels; public uint Colors, ImportantColors; }
    [StructLayout(LayoutKind.Sequential)] private struct Size { public int Width, Height; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] private struct Blend
    { public byte Operation, Flags, ConstantAlpha, AlphaFormat; }
    [DllImport("gdi32.dll")] private static extern nint CreateCompatibleDC(nint dc);
    [DllImport("gdi32.dll")] private static extern nint CreateDIBSection(nint dc, ref BitmapInfo info,
        uint usage, out nint bits, nint section, uint offset);
    [DllImport("gdi32.dll")] private static extern nint SelectObject(nint dc, nint obj);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(nint obj);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(nint dc);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool UpdateLayeredWindow(nint window,
        nint destinationDC, ref Native.Point position, ref Size size, nint sourceDC, ref Native.Point origin,
        uint colorKey, ref Blend blend, uint flags);
}

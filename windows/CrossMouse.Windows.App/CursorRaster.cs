using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace CrossMouse.Windows.App;

/// <summary>
/// Converts Win32 alpha AND/XOR cursor resources to owned premultiplied pixels.
/// A color-keyed Form cannot represent those semantics: e.g. a magenta cursor
/// becomes transparent, and XOR I-beams invert the key instead of the desktop.
/// Draw on black AND white to recover opacity; inverted pixels receive an
/// opaque outlined representation because inversion is not an alpha operation.
/// No screenshot or underlying application pixels are read.
/// </summary>
internal sealed record CursorRaster(int Width, int Height, int HotX, int HotY,
    byte[] Pixels, bool UsedFallback, int InvertedPixels = 0)
{
    internal int VisiblePixels => Enumerable.Range(0, Width * Height).Count(i => Pixels[i * 4 + 3] != 0);

    internal static CursorRaster Capture(nint borrowedCursor)
    {
        nint copy = borrowedCursor == 0 ? 0 : CopyIcon(borrowedCursor);
        if (copy == 0) return Fallback();
        IconInfo info = default;
        try
        {
            if (!GetIconInfo(copy, out info)) return Fallback();
            nint dimensions = info.Color != 0 ? info.Color : info.Mask;
            if (GetObjectW(dimensions, Marshal.SizeOf<NativeBitmap>(), out var bitmap) == 0) return Fallback();
            int width = bitmap.Width, height = info.Color != 0 ? bitmap.Height : bitmap.Height / 2;
            if (width is < 1 or > 256 || height is < 1 or > 256 || info.HotX >= width || info.HotY >= height)
                return Fallback();
            using var black = Draw(copy, width, height, Color.Black);
            using var white = Draw(copy, width, height, Color.White);
            var image = Decode(Read(black), Read(white), width, height, (int)info.HotX, (int)info.HotY);
            return image.VisiblePixels == 0 ? Fallback() : image;
        }
        catch (ArgumentException) { return Fallback(); }
        catch (ExternalException) { return Fallback(); }
        finally
        {
            if (info.Color != 0) DeleteObject(info.Color);
            if (info.Mask != 0) DeleteObject(info.Mask);
            DestroyIcon(copy); // never destroy another process's cursor handle
        }
    }

    internal static CursorRaster Decode(byte[] black, byte[] white, int width, int height, int hotX, int hotY)
    {
        if (width is < 1 or > 256 || height is < 1 or > 256 ||
            black.Length != width * height * 4 || white.Length != black.Length)
            throw new ArgumentException("Invalid bounded cursor buffers.");
        const int pad = 1;
        int outWidth = width + pad * 2, outHeight = height + pad * 2, inverted = 0;
        byte[] result = new byte[outWidth * outHeight * 4];
        for (int y = 0; y < height; y++)
        for (int x = 0; x < width; x++)
        {
            int source = (y * width + x) * 4, target = ((y + pad) * outWidth + x + pad) * 4;
            int d0 = white[source] - black[source], d1 = white[source + 1] - black[source + 1],
                d2 = white[source + 2] - black[source + 2];
            int median = d0 + d1 + d2 - Math.Min(d0, Math.Min(d1, d2)) - Math.Max(d0, Math.Max(d1, d2));
            bool invert = median < -8;
            int alpha = invert ? 255 : Math.Clamp(255 - median, 0, 255);
            if (invert) inverted++;
            result[target] = invert ? (byte)0 : (byte)Math.Min(alpha, black[source]);
            result[target + 1] = invert ? (byte)0 : (byte)Math.Min(alpha, black[source + 1]);
            result[target + 2] = invert ? (byte)0 : (byte)Math.Min(alpha, black[source + 2]);
            result[target + 3] = (byte)alpha;
        }
        // A hardware cursor may depend on background inversion/theme handling.
        // Even a valid all-white I-beam disappears when copied onto a white
        // Chrome page. Give every software glyph a contrasting one-pixel rim,
        // selected from the local edge color, without reading the desktop.
        {
            byte[] original = (byte[])result.Clone();
            for (int y = 1; y < outHeight - 1; y++)
            for (int x = 1; x < outWidth - 1; x++)
            {
                int pixel = (y * outWidth + x) * 4;
                int alpha = original[pixel + 3];
                if (alpha < 64) continue;
                int brightness = (original[pixel] + original[pixel + 1] + original[pixel + 2]) * 255 / (3 * alpha);
                byte contrast = brightness >= 128 ? (byte)0 : (byte)255;
                foreach (int offset in new[] { -outWidth, outWidth, -1, 1 })
                {
                    int neighbor = pixel + offset * 4;
                    if (original[neighbor + 3] == 0)
                    {
                        result[neighbor] = result[neighbor + 1] = result[neighbor + 2] = contrast;
                        result[neighbor + 3] = 255;
                    }
                }
            }
        }
        return new(outWidth, outHeight, hotX + pad, hotY + pad, result, false, inverted);
    }

    internal static CursorRaster Fallback()
    {
        using var bitmap = new Bitmap(28, 36, PixelFormat.Format32bppPArgb);
        using (var graphics = Graphics.FromImage(bitmap))
        using (var path = new GraphicsPath())
        using (var pen = new Pen(Color.Black, 2))
        {
            graphics.Clear(Color.Transparent);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            path.AddPolygon(new Point[] { new(3, 2), new(3, 26), new(9, 21), new(15, 33),
                new(20, 30), new(14, 19), new(23, 19) });
            graphics.FillPath(Brushes.White, path); graphics.DrawPath(pen, path);
        }
        return new(bitmap.Width, bitmap.Height, 3, 2, Read(bitmap), true);
    }

    private static Bitmap Draw(nint cursor, int width, int height, Color background)
    {
        var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        try
        {
            using var graphics = Graphics.FromImage(bitmap);
            graphics.Clear(background);
            nint dc = graphics.GetHdc();
            try { if (!DrawIconEx(dc, 0, 0, cursor, width, height, 0, 0, 3)) throw new ExternalException("Cursor draw failed."); }
            finally { graphics.ReleaseHdc(dc); }
            return bitmap;
        }
        catch { bitmap.Dispose(); throw; }
    }

    internal static byte[] Read(Bitmap bitmap)
    {
        var format = bitmap.PixelFormat == PixelFormat.Format32bppPArgb ? PixelFormat.Format32bppPArgb : PixelFormat.Format32bppArgb;
        var data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadOnly, format);
        try
        {
            byte[] bytes = new byte[bitmap.Width * bitmap.Height * 4];
            for (int y = 0; y < bitmap.Height; y++)
                Marshal.Copy(data.Scan0 + y * data.Stride, bytes, y * bitmap.Width * 4, bitmap.Width * 4);
            return bytes;
        }
        finally { bitmap.UnlockBits(data); }
    }

    [StructLayout(LayoutKind.Sequential)] private struct IconInfo
    { [MarshalAs(UnmanagedType.Bool)] public bool Icon; public uint HotX, HotY; public nint Mask, Color; }
    [StructLayout(LayoutKind.Sequential)] private struct NativeBitmap
    { public int Type, Width, Height, WidthBytes; public ushort Planes, BitsPixel; public nint Bits; }
    [DllImport("user32.dll")] private static extern nint CopyIcon(nint handle);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(nint handle);
    [DllImport("user32.dll")] private static extern bool GetIconInfo(nint handle, out IconInfo info);
    [DllImport("gdi32.dll")] private static extern int GetObjectW(nint bitmap, int size, out NativeBitmap info);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(nint bitmap);
    [DllImport("user32.dll")] private static extern bool DrawIconEx(nint dc, int x, int y, nint icon,
        int width, int height, uint step, nint brush, uint flags);
}

using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

internal static class ReliabilityRegression
{
    internal static int Run()
    {
        try
        {
            CheckMotion(); CheckRasters();
            Console.WriteLine("PASS source-timed motion, cursor opacity/hotspots/resources and fallback");
            // The owned-profile browser fixture is CI-only. Ordinary local
            // diagnostics never inspect, attach to or launch a user browser.
            if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true")
                Require(ChromePointerRegression.Run() == 0, "Real Chrome pointer composition failed.");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine($"FAIL reliability: {error}"); return 1; }
    }

    private static void CheckMotion()
    {
        var motion = new MotionSmoother();
        int sum = 0;
        for (int i = 0; i < 120; i++)
        {
            motion.AddAt(12, -6, i * 8, 1_000_000 + i * 8000);
            var step = motion.StepAt(i * 8 + 8);
            sum += step.Dx;
            if (i > 3) Require(step == (12, -6), $"Uniform source movement acquired uneven frame steps: {step}");
        }
        sum += motion.Drain().Dx;
        Require(sum == 1440, "Uniform input lost distance.");
        Console.WriteLine("PASS steady 125Hz source: equal frame steps after startup, exact distance");

        int[] arrivals = [0, 8, 16, 48, 48, 48, 56, 80, 80, 88, 112, 112];
        int index = 0; sum = 0; int maxStep = 0;
        for (int time = 0; time <= 200; time += 4)
        {
            while (index < arrivals.Length && arrivals[index] <= time)
            {
                motion.AddAt(10, 0, time, 2_000_000 + index * 8000); index++;
            }
            var step = motion.StepAt(time);
            Require(step.Dx >= 0 && step.Dy == 0, "Playout invented reverse/vertical movement.");
            sum += step.Dx; maxStep = Math.Max(maxStep, step.Dx);
        }
        Require(sum == 120 && !motion.HasPending, "Late burst lost distance or retained a long backlog.");
        Require(maxStep < 30, "A three-packet delivery burst became one instantaneous jump.");
        motion.AddAt(27, -18, 208, 2_208_000);
        var beforeClick = motion.StepAt(212);
        var atClick = motion.Drain();
        Require(beforeClick.Dx + atClick.Dx == 27 && beforeClick.Dy + atClick.Dy == -18,
            "Click did not include all preceding movement.");
        motion.AddAt(100, 0, 300); motion.Reset();
        Require(motion.StepAt(1000) == (0, 0), "Prior-owner movement survived release.");
        for (int i = 0; i < 10000; i++) motion.AddAt(1, -1, i * 0.01, i * 8000);
        Require(motion.BufferedSamples <= 64, "Motion queue grew without a bound.");
        Console.WriteLine($"PASS replayed 8-32ms delivery jitter: max 4ms-frame delta={maxStep}, click barrier, reset, bounded backlog");
    }

    private static void CheckRasters()
    {
        string directory = Path.Combine("diagnostics", "cursor-renders");
        Directory.CreateDirectory(directory);
        var cursors = new (string Name, Cursor Cursor)[] {
            ("arrow", Cursors.Arrow), ("ibeam", Cursors.IBeam), ("hand", Cursors.Hand),
            ("cross", Cursors.Cross), ("size-we", Cursors.SizeWE), ("wait", Cursors.WaitCursor), ("no", Cursors.No) };
        foreach (var (name, cursor) in cursors)
        {
            var raster = CursorRaster.Capture(cursor.Handle);
            CheckRaster(raster, name);
            Save(raster, Path.Combine(directory, name + "-light.png"), Color.White);
            Save(raster, Path.Combine(directory, name + "-dark.png"), Color.FromArgb(25, 25, 25));
        }
        CheckRaster(CursorRaster.Capture(0), "null native handle");
        using var magenta = new Bitmap(32, 32, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(magenta)) graphics.Clear(Color.Magenta);
        nint color = magenta.GetHbitmap(Color.Transparent), mask = CreateBitmap(32, 32, 1, 1, new byte[128]);
        var info = new IconInfo { HotX = 4, HotY = 7, Color = color, Mask = mask };
        nint custom = CreateIconIndirect(ref info);
        try
        {
            Require(custom != 0, "Could not create real color cursor fixture.");
            using var old = new Bitmap(32, 32, PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(old))
            {
                graphics.Clear(Color.Magenta); var dc = graphics.GetHdc();
                try { Require(DrawIconEx(dc, 0, 0, custom, 32, 32, 0, 0, 3), "Legacy draw failed."); }
                finally { graphics.ReleaseHdc(dc); }
            }
            int oldVisible = 0;
            for (int y = 0; y < old.Height; y++)
            for (int x = 0; x < old.Width; x++) if (old.GetPixel(x, y).ToArgb() != Color.Magenta.ToArgb()) oldVisible++;
            var fixedRaster = CursorRaster.Capture(custom);
            Require(oldVisible == 0, "Legacy transparency fixture did not reproduce.");
            Require(fixedRaster.VisiblePixels >= 1024 && !fixedRaster.UsedFallback,
                "Opaque color cursor still became transparent.");
            Require(fixedRaster.HotX == 5 && fixedRaster.HotY == 8, "Real cursor hotspot was not preserved with border padding.");
            Save(fixedRaster, Path.Combine(directory, "opaque-magenta-fixed.png"), Color.White);
            Console.WriteLine($"REPRO old color-key compositor: visible pixels={oldVisible}; alpha compositor={fixedRaster.VisiblePixels}");
        }
        finally
        {
            if (custom != 0) DestroyIcon(custom);
            DeleteObject(color); DeleteObject(mask);
        }
        // Exact XOR truth table: inversion is opaque black + contrast rim, not transparency.
        byte[] blackBackground = [255, 255, 255, 0], whiteBackground = [0, 0, 0, 0];
        var inverse = CursorRaster.Decode(blackBackground, whiteBackground, 1, 1, 0, 0);
        Require(inverse.InvertedPixels == 1 && inverse.VisiblePixels == 5, "XOR inversion was lost.");
        Console.WriteLine("PASS native arrow/I-beam/hand/resize/wait, alpha color, XOR, null handles and hotspot pixel fixtures");
    }
    private static void CheckRaster(CursorRaster raster, string name)
    {
        Require(raster.VisiblePixels >= 5, $"{name}: no visible pixels");
        Require(raster.HotX >= 0 && raster.HotX < raster.Width && raster.HotY >= 0 && raster.HotY < raster.Height,
            $"{name}: invalid hotspot");
        int darkInk = 0, lightInk = 0;
        for (int i = 0; i < raster.Pixels.Length; i += 4)
        {
            Require(raster.Pixels[i] <= raster.Pixels[i + 3] && raster.Pixels[i + 1] <= raster.Pixels[i + 3] &&
                raster.Pixels[i + 2] <= raster.Pixels[i + 3], $"{name}: invalid premultiplied alpha");
            int brightness = (raster.Pixels[i] + raster.Pixels[i + 1] + raster.Pixels[i + 2]) / 3;
            int alpha = raster.Pixels[i + 3];
            if (alpha - brightness >= 80) darkInk++;
            if (brightness >= 80) lightInk++;
        }
        Require(darkInk >= 5 && lightInk >= 5, $"{name}: cursor is not readable on both light and dark content ({darkInk}/{lightInk}).");
    }
    private static void Save(CursorRaster raster, string path, Color background)
    {
        using var shape = new Bitmap(raster.Width, raster.Height, PixelFormat.Format32bppPArgb);
        var data = shape.LockBits(new Rectangle(0, 0, shape.Width, shape.Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppPArgb);
        try { for (int y = 0; y < raster.Height; y++) Marshal.Copy(raster.Pixels, y * raster.Width * 4, data.Scan0 + y * data.Stride, raster.Width * 4); }
        finally { shape.UnlockBits(data); }
        using var preview = new Bitmap(240, 160);
        using (var graphics = Graphics.FromImage(preview))
        {
            graphics.Clear(background);
            graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
            graphics.DrawImage(shape, new Rectangle(24, 16, shape.Width * 3, shape.Height * 3));
        }
        preview.Save(path, ImageFormat.Png);
    }
    private static void Require(bool value, string failure) { if (!value) throw new Exception(failure); }
    [StructLayout(LayoutKind.Sequential)] private struct IconInfo
    { [MarshalAs(UnmanagedType.Bool)] public bool Icon; public uint HotX, HotY; public nint Mask, Color; }
    [DllImport("user32.dll")] private static extern nint CreateIconIndirect(ref IconInfo info);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(nint handle);
    [DllImport("gdi32.dll")] private static extern nint CreateBitmap(int width, int height, uint planes, uint bits, byte[] data);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(nint handle);
    [DllImport("user32.dll")] private static extern bool DrawIconEx(nint dc, int x, int y, nint icon,
        int width, int height, uint step, nint brush, uint flags);
}

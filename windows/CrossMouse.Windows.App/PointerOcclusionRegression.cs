using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

/// <summary>
/// CI-only desktop fixture. Keeps ONE remote presentation lease visible while
/// another topmost window appears above it. Never hide/show the pointer between
/// samples: that would itself raise its z-order and conceal this regression.
/// No pairing file, service, user application, display input or password is used.
/// </summary>
internal static class PointerOcclusionRegression
{
    internal static int Run()
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true") return 5;
        using var watchdog = new System.Threading.Timer(_ =>
        {
            Console.Error.WriteLine("FAIL pointer occlusion watchdog (25s)");
            Environment.Exit(1);
        }, null, TimeSpan.FromSeconds(25), Timeout.InfiniteTimeSpan);
        using var host = new Form
        {
            Text = "CrossMouse CI occlusion fixture", StartPosition = FormStartPosition.Manual,
            Location = new Point(100, 100), ClientSize = new Size(500, 360),
            AutoScaleMode = AutoScaleMode.None, BackColor = Color.FromArgb(68, 102, 136)
        };
        int result = 1;
        host.Shown += async (_, _) =>
        {
            try { await CheckAsync(host); result = 0; }
            catch (Exception error) { Console.Error.WriteLine($"FAIL pointer occlusion: {error}"); }
            finally { host.Close(); }
        };
        Application.Run(host);
        return result;
    }

    private static async Task CheckAsync(Form host)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        CancellationToken token = timeout.Token;
        bool restore = Native.GetCursorPos(out var original);
        int active = 1;
        using var presenter = new PointerPresenter(() => Volatile.Read(ref active) == 1);
        using var popup = new Form
        {
            Text = "Owned CI popup", StartPosition = FormStartPosition.Manual,
            FormBorderStyle = FormBorderStyle.None, AutoScaleMode = AutoScaleMode.None,
            Bounds = host.RectangleToScreen(host.ClientRectangle),
            TopMost = true, ShowInTaskbar = false, BackColor = Color.FromArgb(112, 144, 176)
        };
        var button = new Button { Text = "CI click target", Location = new Point(20, 20), Size = new Size(150, 40) };
        int clicks = 0;
        button.Click += (_, _) => clicks++;
        popup.Controls.Add(button);
        Point point = host.PointToScreen(new Point(260, 220));
        string evidence = Path.Combine("diagnostics", "cursor-renders");
        Directory.CreateDirectory(evidence);
        try
        {
            Require(Native.SetCursorPos(point.X, point.Y) && Native.WakePointerAt(point.X, point.Y),
                "Could not place fixture cursor.");
            await Task.Delay(60, token);
            Require(await presenter.VerifyAsync(token), "Initial pointer surface was unavailable.");
            await Task.Delay(30, token);
            int before = VisibleInk(point, host.BackColor, Path.Combine(evidence, "stack-before-popup.png"));
            Require(before >= 8, "No initial cursor pixels on the controlled solid background.");

            // This popup did not exist when the pointer was shown. TopMost is
            // a group, not an immutable priority over every future topmost HWND.
            popup.Show();
            await Task.Delay(80, token);
            nint foreground = GetForegroundWindow();
            bool reportedVisible = await presenter.VerifyAsync(token);
            await Task.Delay(30, token);
            int after = VisibleInk(point, popup.BackColor, Path.Combine(evidence, "stack-after-popup.png"));
            Console.WriteLine($"MEASURE same lease after later topmost popup: reported={reportedVisible}, pixels={after}, state={presenter.State}");
            Require(reportedVisible && after >= 8,
                "A later topmost popup covered the remote pointer while presentation still reported success.");
            Require(GetForegroundWindow() == foreground, "Pointer stacking stole foreground activation.");

            // Repeatedly raise the same live popup, keep the pointer stationary
            // on some iterations and move it on others. No pointer lease reset.
            for (int i = 0; i < 12; i++)
            {
                Require(SetWindowPos(popup.Handle, new nint(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010),
                    "Could not establish controlled topmost order.");
                if ((i & 1) != 0)
                {
                    point.X += 2;
                    Require(Native.SetCursorPos(point.X, point.Y) && Native.WakePointerAt(point.X, point.Y),
                        "Fixture motion failed.");
                }
                Require(await presenter.VerifyAsync(token), "Refresh lost the same presentation lease.");
                await Task.Delay(20, token);
                Require(VisibleInk(point, popup.BackColor) >= 8, $"Pointer occluded on repeated raise {i}.");
                Require(GetForegroundWindow() == foreground, "A repeated refresh activated the pointer.");
            }
            Console.WriteLine("PASS stationary and moving pointer survives 12 later popup raises without hide/show or focus theft");

            Point click = button.PointToScreen(new Point(60, 20));
            Require(Native.SetCursorPos(click.X, click.Y) && Native.WakePointerAt(click.X, click.Y), "Click target placement failed.");
            Require(await presenter.VerifyAsync(token), "No pointer at click target.");
            // SendInput is outside the UI thread, as in the production receiver.
            await Task.Run(() => Require(Native.MouseButton(0, true) && Native.MouseButton(0, false), "Injected click failed."), token);
            await Task.Delay(60, token);
            Require(clicks == 1, "The repaired topmost pointer intercepted the underlying button click.");

            popup.Hide();
            point = host.PointToScreen(new Point(260, 220));
            Native.SetCursorPos(point.X, point.Y); Native.WakePointerAt(point.X, point.Y);
            Require(await presenter.VerifyAsync(token), "Pointer did not survive popup dismissal.");
            await Task.Delay(30, token);
            Require(VisibleInk(point, host.BackColor) >= 8, "Pointer vanished after popup dismissal.");
            Volatile.Write(ref active, 0);
            Require(!await presenter.VerifyAsync(token), "Released pointer still reported presented.");
            await Task.Delay(30, token);
            Require(VisibleInk(point, host.BackColor) == 0, "Pointer drawing survived input release.");
            Console.WriteLine("PASS click-through, popup dismissal and input-release hiding");
        }
        finally
        {
            Volatile.Write(ref active, 0);
            if (popup.Visible) popup.Hide();
            if (restore) Native.SetCursorPos(original.X, original.Y);
        }
    }

    private static int VisibleInk(Point point, Color background, string? file = null)
    {
        DwmFlush();
        using var image = new Bitmap(96, 96, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(image))
        {
            nint destination = graphics.GetHdc(), source = GetDC(0);
            try
            {
                Require(source != 0 && BitBlt(destination, 0, 0, 96, 96, source,
                    point.X - 24, point.Y - 24, 0x00CC0020 | 0x40000000), "Layered pixel capture failed.");
            }
            finally { if (source != 0) ReleaseDC(0, source); graphics.ReleaseHdc(destination); }
        }
        int changed = 0;
        for (int y = 0; y < image.Height; y++)
        for (int x = 0; x < image.Width; x++)
        {
            Color pixel = image.GetPixel(x, y);
            if (Math.Abs(pixel.R - background.R) + Math.Abs(pixel.G - background.G) + Math.Abs(pixel.B - background.B) >= 90)
                changed++;
        }
        if (file is not null) image.Save(file, ImageFormat.Png);
        return changed;
    }

    private static void Require(bool value, string message) { if (!value) throw new Exception(message); }
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SetWindowPos(nint window, nint after,
        int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern nint GetDC(nint window);
    [DllImport("user32.dll")] private static extern int ReleaseDC(nint window, nint dc);
    [DllImport("gdi32.dll")] private static extern bool BitBlt(nint target, int x, int y, int width, int height,
        nint source, int sx, int sy, uint operation);
    [DllImport("dwmapi.dll")] private static extern int DwmFlush();
}

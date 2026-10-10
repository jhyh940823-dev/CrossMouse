using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

/// <summary>
/// CI-only visible-compositor check against an OWNED fresh Chrome profile and
/// local fixture, plus Chrome's real folder picker. Never attaches to the user's
/// browser, reads real pages, selects a file, or sends data to an external site.
/// Pixel crops contain only the test page/picker and are uploaded as evidence.
/// </summary>
internal static class ChromePointerRegression
{
    internal static int Run()
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true") return 5;
        try { RunAsync().GetAwaiter().GetResult(); return 0; }
        catch (Exception error) { Console.Error.WriteLine($"FAIL real Chrome pointer: {error}"); return 1; }
    }

    private static async Task RunAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(45));
        var token = timeout.Token;
        string? chrome = new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) }
            .Select(root => Path.Combine(root, "Google", "Chrome", "Application", "chrome.exe")).FirstOrDefault(File.Exists);
        if (chrome is null) throw new FileNotFoundException("The Windows integration runner must contain Chrome; not silently skipped.");
        string directory = Path.Combine(Path.GetTempPath(), "CrossMouse-Chrome-CI-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        string htmlPath = Path.Combine(directory, "pointer-fixture.html");
        File.WriteAllText(htmlPath, """
            <!doctype html><title>CrossMouse isolated pointer fixture</title>
            <style>body{margin:25px;background:white;color:#555;font:18px sans-serif}
            .box{display:block;box-sizing:border-box;width:500px;height:75px;margin:10px;padding:15px;border:1px solid #888}
            button{font:18px sans-serif;cursor:pointer}</style>
            <button id=hand class=box onclick="window.clickCount=(window.clickCount||0)+1">Pointer hand / click test</button>
            <input id=text class=box value="Text cursor fixture" style="cursor:text">
            <div id=resize class=box style="cursor:ew-resize">Resize cursor fixture</div>
            <div id=hidden class=box style="cursor:none">Intentionally hidden native cursor: must remain operable</div>
            <button id=folder class=box onclick="document.querySelector('#files').click()">Open isolated folder picker</button>
            <input id=files type=file webkitdirectory hidden>
            """);
        var start = new ProcessStartInfo(chrome) { UseShellExecute = false };
        foreach (string argument in new[] { "--user-data-dir=" + Path.Combine(directory, "profile"),
            "--remote-debugging-port=0", "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
            "--window-position=50,50", "--window-size=900,780", new Uri(htmlPath).AbsoluteUri }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("Could not start the isolated Chrome fixture.");
        Native.GetCursorPos(out var originalPointer);
        int active = 0;
        using var presenter = new PointerPresenter(() => Volatile.Read(ref active) != 0, simulateHiddenNativePointerForTest: true);
        nint dialog = 0;
        try
        {
            var portFile = Path.Combine(directory, "profile", "DevToolsActivePort");
            while (!File.Exists(portFile)) await Task.Delay(100, token);
            int port = int.Parse(File.ReadLines(portFile).First());
            using var http = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}") };
            string? endpoint = null;
            while (endpoint is null)
            {
                using var pages = JsonDocument.Parse(await http.GetStringAsync("/json/list", token));
                foreach (var page in pages.RootElement.EnumerateArray())
                    if (page.GetProperty("type").GetString() == "page" && page.GetProperty("url").GetString()?.Contains("pointer-fixture.html") == true)
                        endpoint = page.GetProperty("webSocketDebuggerUrl").GetString();
                if (endpoint is null) await Task.Delay(100, token);
            }
            using var cdp = new Cdp();
            await cdp.ConnectAsync(endpoint, token);
            await cdp.CallAsync("Page.bringToFront", new { }, token);
            while ((await cdp.EvaluateAsync("document.readyState", token)).GetString() != "complete") await Task.Delay(30, token);
            string evidence = Path.Combine("diagnostics", "cursor-renders"); Directory.CreateDirectory(evidence);
            foreach (string theme in new[] { "light", "dark" })
            {
                await cdp.EvaluateAsync($"document.body.style.background='{(theme == "light" ? "white" : "#191919")}'", token);
                foreach (string element in new[] { "hand", "text", "resize", "hidden" })
                {
                    Point point = await ElementPoint(cdp, element, token);
                    Require(Native.SetCursorPos(point.X, point.Y) && Native.WakePointerAt(point.X, point.Y), "Native Chrome move rejected.");
                    await Task.Delay(80, token);
                    await CheckSurfaceAt(presenter, point, () => Volatile.Write(ref active, 0),
                        () => Volatile.Write(ref active, 1), Path.Combine(evidence, $"chrome-{element}-{theme}.png"), token);
                }
            }
            // Prove the overlay does not steal clicks from another process.
            var hand = await ElementPoint(cdp, "hand", token);
            Native.SetCursorPos(hand.X, hand.Y); Native.WakePointerAt(hand.X, hand.Y);
            await presenter.VerifyAsync(token);
            Require(Native.MouseButton(0, true) && Native.MouseButton(0, false), "Native Chrome click rejected.");
            await Task.Delay(100, token);
            Require((await cdp.EvaluateAsync("window.clickCount||0", token)).GetInt32() == 1, "Pointer overlay intercepted Chrome click.");
            Console.WriteLine("PASS visible software hand/I-beam/resize/hidden-pointer fallback over real Chrome light/dark content; click-through verified");

            Point folder = await ElementPoint(cdp, "folder", token);
            Native.SetCursorPos(folder.X, folder.Y); Native.WakePointerAt(folder.X, folder.Y);
            await Task.Delay(80, token);
            Native.MouseButton(0, true); Native.MouseButton(0, false);
            for (int attempt = 0; attempt < 40; attempt++)
            {
                nint foreground = GetForegroundWindow();
                var name = new StringBuilder(100); GetClassNameW(foreground, name, name.Capacity);
                if (name.ToString() == "#32770") { dialog = foreground; break; }
                await Task.Delay(100, token);
            }
            Require(dialog != 0 && GetWindowRect(dialog, out _), "Chrome's real folder dialog did not open.");
            GetWindowRect(dialog, out var bounds);
            var center = new Point((bounds.Left + bounds.Right) / 2, (bounds.Top + bounds.Bottom) / 2);
            Native.SetCursorPos(center.X, center.Y); Native.WakePointerAt(center.X, center.Y);
            await Task.Delay(80, token);
            await CheckSurfaceAt(presenter, center, () => Volatile.Write(ref active, 0),
                () => Volatile.Write(ref active, 1), Path.Combine(evidence, "chrome-folder-dialog.png"), token);
            PostMessageW(dialog, 0x10, 0, 0); dialog = 0; // cancel our own picker, select nothing
            Console.WriteLine("PASS alpha pointer remains visible over Chrome folder-selection dialog without selecting any file");
        }
        finally
        {
            Volatile.Write(ref active, 0);
            if (dialog != 0) PostMessageW(dialog, 0x10, 0, 0);
            if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); }
            Native.SetCursorPos(originalPointer.X, originalPointer.Y);
            try { Directory.Delete(directory, recursive: true); } catch (IOException) { }
        }
    }

    private static async Task<Point> ElementPoint(Cdp cdp, string id, CancellationToken token)
    {
        var point = await cdp.EvaluateAsync($$"""
            (()=>{let r=document.querySelector('#{{id}}').getBoundingClientRect();let b=(outerWidth-innerWidth)/2;
            return {x:Math.round((screenX+b+r.x+r.width/2)*devicePixelRatio),
                    y:Math.round((screenY+outerHeight-innerHeight-b+r.y+r.height/2)*devicePixelRatio)};})()
            """, token);
        return new(point.GetProperty("x").GetInt32(), point.GetProperty("y").GetInt32());
    }
    private static async Task CheckSurfaceAt(PointerPresenter presenter, Point point, Action hide, Action show,
        string file, CancellationToken token)
    {
        hide(); await presenter.VerifyAsync(token); await Task.Delay(25, token); DwmFlush();
        var region = new Rectangle(point.X - 16, point.Y - 16, 100, 100);
        using var before = Crop(region);
        nint foreground = GetForegroundWindow();
        show(); Require(await presenter.VerifyAsync(token), "Cursor surface not presented on Chrome.");
        await Task.Delay(25, token); DwmFlush();
        Require(GetForegroundWindow() == foreground, "Cursor surface stole foreground focus.");
        using var after = Crop(region);
        int changed = 0;
        for (int y = 0; y < region.Height; y++)
        for (int x = 0; x < region.Width; x++)
        {
            var a = before.GetPixel(x, y); var b = after.GetPixel(x, y);
            if (Math.Abs(a.R - b.R) + Math.Abs(a.G - b.G) + Math.Abs(a.B - b.B) >= 90) changed++;
        }
        after.Save(file, ImageFormat.Png);
        Require(changed >= 8, $"Layered cursor made no readable pixel change on Chrome ({changed}): {Path.GetFileName(file)}");
    }
    private static Bitmap Crop(Rectangle region)
    {
        // Graphics.CopyFromScreen validates enum members and rejects the
        // SRCCOPY|CAPTUREBLT combination. Native BitBlt accepts it and includes
        // the layered pointer rather than silently testing the browser alone.
        var bitmap = new Bitmap(region.Width, region.Height);
        try
        {
            using var graphics = Graphics.FromImage(bitmap);
            nint source = GetDC(0);
            if (source == 0) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            nint destination = 0;
            try
            {
                destination = graphics.GetHdc();
                if (!BitBlt(destination, 0, 0, region.Width, region.Height, source, region.X, region.Y, 0x40CC0020))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CI layered crop failed.");
            }
            finally
            {
                if (destination != 0) graphics.ReleaseHdc(destination);
                ReleaseDC(0, source);
            }
            return bitmap;
        }
        catch { bitmap.Dispose(); throw; }
    }
    private sealed class Cdp : IDisposable
    {
        private readonly ClientWebSocket _socket = new();
        private int _id;
        internal Task ConnectAsync(string endpoint, CancellationToken token) => _socket.ConnectAsync(new Uri(endpoint), token);
        internal async Task<JsonElement> CallAsync(string method, object parameters, CancellationToken token)
        {
            int id = ++_id;
            await _socket.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { id, method, @params = parameters }),
                WebSocketMessageType.Text, true, token);
            byte[] buffer = new byte[65536];
            while (true)
            {
                using var message = new MemoryStream();
                WebSocketReceiveResult part;
                do
                {
                    part = await _socket.ReceiveAsync(new ArraySegment<byte>(buffer), token);
                    if (part.MessageType == WebSocketMessageType.Close || message.Length + part.Count > 262144) throw new IOException("Invalid bounded CDP response.");
                    message.Write(buffer, 0, part.Count);
                } while (!part.EndOfMessage);
                using var parsed = JsonDocument.Parse(message.ToArray());
                if (!parsed.RootElement.TryGetProperty("id", out var responseId) || responseId.GetInt32() != id) continue;
                if (parsed.RootElement.TryGetProperty("error", out var error)) throw new IOException(error.ToString());
                return parsed.RootElement.GetProperty("result").Clone();
            }
        }
        internal async Task<JsonElement> EvaluateAsync(string expression, CancellationToken token)
        {
            var result = await CallAsync("Runtime.evaluate", new { expression, returnByValue = true }, token);
            return result.GetProperty("result").GetProperty("value").Clone();
        }
        public void Dispose() => _socket.Dispose();
    }
    private static void Require(bool value, string message) { if (!value) throw new Exception(message); }
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint window, out Rect bounds);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(nint window, StringBuilder name, int count);
    [DllImport("user32.dll")] private static extern bool PostMessageW(nint window, uint message, nuint wParam, nint lParam);
    [DllImport("dwmapi.dll")] private static extern int DwmFlush();
    [DllImport("user32.dll", SetLastError = true)] private static extern nint GetDC(nint window);
    [DllImport("user32.dll")] private static extern int ReleaseDC(nint window, nint dc);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern bool BitBlt(nint dest, int x, int y,
        int width, int height, nint source, int sourceX, int sourceY, uint operation);
}

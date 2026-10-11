using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

// CI-only visible-compositor check against an owned fresh Chrome profile and
// local fixture, including Chrome's native folder picker. Never attaches to a
// user's browser, selects a file, or sends captured content to an external site.
internal static class Program
{
    [STAThread]
    private static int Main()
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true") return 5;
        ApplicationConfiguration.Initialize();
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
        if (chrome is null) throw new FileNotFoundException("Integration runner must contain Chrome; not silently skipped.");
        string directory = Path.Combine(Path.GetTempPath(), "CrossMouse-Chrome-CI-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        string htmlPath = Path.Combine(directory, "pointer-fixture.html");
        File.WriteAllText(htmlPath, """
            <!doctype html><title>CrossMouse isolated pointer fixture</title>
            <style>body{margin:25px;background:white;color:#777;font:18px sans-serif}
            .box{display:block;box-sizing:border-box;width:500px;height:75px;margin:10px;padding:15px;border:1px solid #888;background:inherit;color:inherit}
            button{font:18px sans-serif;cursor:pointer}</style>
            <button id=hand class=box onclick="window.clickCount=(window.clickCount||0)+1">Pointer hand / click test</button>
            <input id=text class=box value="Text cursor fixture" style="cursor:text">
            <div id=resize class=box style="cursor:ew-resize">Resize cursor fixture</div>
            <div id=hidden class=box style="cursor:none">Hidden native cursor: fallback must remain visible</div>
            <button id=folder class=box onclick="window.folderClicks=(window.folderClicks||0)+1;document.querySelector('#files').click()">Open isolated folder picker</button>
            <input id=files type=file webkitdirectory hidden>
            """);
        var start = new ProcessStartInfo(chrome) { UseShellExecute = false };
        foreach (string argument in new[] { "--user-data-dir=" + Path.Combine(directory, "profile"),
            "--remote-debugging-port=0", "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
            "--window-position=50,50", "--window-size=900,780", new Uri(htmlPath).AbsoluteUri }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("Could not start isolated Chrome fixture.");
        Native.GetCursorPos(out var originalPointer);
        int active = 0;
        // Exercise the production constructor: forcing the fallback masked the
        // decision that hides our surface when Windows merely reports SHOWING.
        // The remote session must own a painted pointer across glyph changes.
        using var presenter = new PointerPresenter(() => Volatile.Read(ref active) != 0);
        nint dialog = 0;
        try
        {
            var portFile = Path.Combine(directory, "profile", "DevToolsActivePort");
            int port = 0;
            while (port == 0)
            {
                // File creation precedes Chrome closing/publishing its port.
                // Wait for readable valid content, not merely File.Exists.
                try
                {
                    if (File.Exists(portFile) && int.TryParse(File.ReadLines(portFile).FirstOrDefault(), out int candidate)
                        && candidate is > 0 and <= 65535) port = candidate;
                }
                catch (IOException) { /* owned Chrome is still writing */ }
                if (port == 0) await Task.Delay(25, token);
            }
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
                foreach (string element in new[] { "hand", "text", "resize", "hidden", "text", "hand" })
                {
                    Point point = await ElementPoint(cdp, element, token);
                    Require(Native.SetCursorPos(point.X, point.Y) && Native.WakePointerAt(point.X, point.Y), "Chrome move rejected.");
                    await Task.Delay(80, token);
                    await CheckSurfaceAt(presenter, point, () => Volatile.Write(ref active, 0),
                        () => Volatile.Write(ref active, 1), Path.Combine(evidence, $"chrome-{element}-{theme}.png"), token);
                }
            }
            var hand = await ElementPoint(cdp, "hand", token);
            Native.SetCursorPos(hand.X, hand.Y); Native.WakePointerAt(hand.X, hand.Y);
            await presenter.VerifyAsync(token);
            Require(Native.MouseButton(0, true) && Native.MouseButton(0, false), "Chrome click rejected.");
            await Task.Delay(100, token);
            Require((await cdp.EvaluateAsync("window.clickCount||0", token)).GetInt32() == 1, "Pointer overlay intercepted Chrome click.");
            Console.WriteLine("PASS production default pointer across Chrome hand/text/resize/hidden/text/hand; no forced fallback; click-through verified");

            await cdp.CallAsync("Page.bringToFront", new { }, token);
            await cdp.EvaluateAsync("document.querySelector('#folder').scrollIntoView({block:'center'});true", token);
            await Task.Delay(60, token);
            Point folder = await ElementPoint(cdp, "folder", token);
            Require(Native.SetCursorPos(folder.X, folder.Y) && Native.WakePointerAt(folder.X, folder.Y),
                "Folder button pointer placement failed.");
            await Task.Delay(80, token);
            Require(Native.MouseButton(0, true) && Native.MouseButton(0, false), "Folder button injection rejected.");
            // Shell first-use startup is asynchronous. Wait for an actual
            // native dialog, not a fixed short delay or a JavaScript substitute.
            var dialogWait = Stopwatch.StartNew();
            while (dialogWait.Elapsed < TimeSpan.FromSeconds(12))
            {
                nint foreground = GetForegroundWindow();
                var name = new StringBuilder(100); GetClassNameW(foreground, name, name.Capacity);
                if (name.ToString() == "#32770") { dialog = foreground; break; }
                await Task.Delay(100, token);
            }
            if (dialog == 0)
            {
                int clicks = (await cdp.EvaluateAsync("window.folderClicks||0", token)).GetInt32();
                var foregroundName = new StringBuilder(100);
                GetClassNameW(GetForegroundWindow(), foregroundName, foregroundName.Capacity);
                Console.WriteLine($"Folder readiness failure: DOM click count={clicks}, foreground class={foregroundName}");
            }
            Require(dialog != 0 && GetWindowRect(dialog, out _), "Chrome's real folder dialog did not open.");
            Console.WriteLine($"MEASURE actual Chrome native folder ready after {dialogWait.ElapsedMilliseconds}ms");
            GetWindowRect(dialog, out var bounds);
            var center = new Point((bounds.Left + bounds.Right) / 2, (bounds.Top + bounds.Bottom) / 2);
            Native.SetCursorPos(center.X, center.Y); Native.WakePointerAt(center.X, center.Y);
            await Task.Delay(80, token);
            await CheckSurfaceAt(presenter, center, () => Volatile.Write(ref active, 0),
                () => Volatile.Write(ref active, 1), Path.Combine(evidence, "chrome-folder-dialog.png"), token);
            PostMessageW(dialog, 0x10, 0, 0); dialog = 0;
            Console.WriteLine("PASS visible pointer over native Chrome folder-selection dialog; no files selected");
        }
        catch
        {
            // An owned CI browser can fail before the usual tiny pointer
            // crops. Preserve the foreground fixture for diagnosis, not merely
            // a green rerun. This program refuses to run on a user's desktop.
            try
            {
                if (GetWindowRect(GetForegroundWindow(), out var failureBounds))
                {
                    var region = Rectangle.Intersect(SystemInformation.VirtualScreen,
                        Rectangle.FromLTRB(failureBounds.Left, failureBounds.Top, failureBounds.Right, failureBounds.Bottom));
                    if (region.Width > 0 && region.Height > 0)
                    {
                        Directory.CreateDirectory(Path.Combine("diagnostics", "cursor-renders"));
                        using var failure = Crop(region);
                        failure.Save(Path.Combine("diagnostics", "cursor-renders", "chrome-failure-context.png"), ImageFormat.Png);
                    }
                }
            }
            catch (Exception) { /* preserve the original failure */ }
            throw;
        }
        finally
        {
            Volatile.Write(ref active, 0);
            if (dialog != 0) PostMessageW(dialog, 0x10, 0, 0);
            if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); }
            Native.SetCursorPos(originalPointer.X, originalPointer.Y);
            try { Directory.Delete(directory, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
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
        Require(changed >= 8, $"No readable pointer pixel change ({changed}): {Path.GetFileName(file)}");
    }
    private static Bitmap Crop(Rectangle region)
    {
        var bitmap = new Bitmap(region.Width, region.Height, PixelFormat.Format32bppArgb);
        try
        {
            using var graphics = Graphics.FromImage(bitmap);
            nint destination = graphics.GetHdc();
            nint source = GetDC(0);
            try
            {
                Require(source != 0 && BitBlt(destination, 0, 0, region.Width, region.Height,
                    source, region.X, region.Y, 0x00CC0020 | 0x40000000), "Layered fixture pixel capture failed.");
            }
            finally
            {
                if (source != 0) ReleaseDC(0, source);
                graphics.ReleaseHdc(destination);
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
    [DllImport("user32.dll")] private static extern nint GetDC(nint window);
    [DllImport("user32.dll")] private static extern int ReleaseDC(nint window, nint dc);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern bool BitBlt(nint target, int x, int y,
        int width, int height, nint source, int sourceX, int sourceY, uint operation);
    [DllImport("dwmapi.dll")] private static extern int DwmFlush();
}

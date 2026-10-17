using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

/// Changes only the isolated CI runner's clipboard. No user's clipboard,
/// pairing files, stored credentials or external application are read.
internal static class ClipboardRegression
{
    internal static int Run()
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true") return 5;
        using var watchdog = new System.Threading.Timer(_ => Environment.Exit(1), null, 30000, Timeout.Infinite);
        using var window = new Form { Text = "CrossMouse clipboard fixture", Width = 640, Height = 420 };
        using var box = new TextBox { Multiline = true, Dock = DockStyle.Fill };
        window.Controls.Add(box);
        int result = 1;
        Native.GetCursorPos(out var original);
        window.Shown += async (_, _) =>
        {
            try
            {
                CheckAssembly();
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
                var token = timeout.Token;
                byte[] key = RandomNumberGenerator.GetBytes(32);
                await using var receiver = new ReceiverService(key, 0);
                receiver.Start();
                using var peer = await RemoteInputRegression.Peer.ConnectAsync(key, receiver.ListeningPort, token);
                Clipboard.SetText("Windows sentinel");
                string id = Guid.NewGuid().ToString();
                await peer.SendAsync(new MouseMessage { Type = "clipboard-begin", TransferId = id,
                    ClipboardId = Guid.NewGuid().ToString(), ClipboardBytes = 4 }, token);
                Require((await peer.ReadAsync(token)).Reason == "unavailable", "Idle clipboard injection accepted.");
                Require(Clipboard.GetText() == "Windows sentinel", "Idle clipboard changed.");
                await peer.SendAsync(new MouseMessage { Type = "prepare", TransferId = id }, token);
                await peer.ExpectAsync("prepared", token);

                string text = "한글🙂\nconst path = \"C:\\code\";\t값\n" + new string('x', 20000);
                Require(await UploadAsync(peer, id, text, token) == "ok", "Unicode chunk upload failed.");
                Require(Clipboard.GetText() == Normalize(text), "Clipboard text differs.");
                uint excluded = RegisterClipboardFormatW("ExcludeClipboardContentFromMonitorProcessing");
                Require(IsClipboardFormatAvailable(excluded), "Windows history/cloud exclusion marker missing.");

                var localFrames = Frames(id, "Mac text should not overwrite newer Windows copy");
                foreach (var frame in localFrames[..^1]) await peer.SendAsync(frame, token);
                await peer.SendAsync(new MouseMessage { Type = "ping" }, token); await peer.ExpectAsync("pong", token);
                Clipboard.SetText("New Windows copy");
                await peer.SendAsync(localFrames[^1], token);
                Require((await peer.ReadAsync(token)).Reason == "local-changed", "Overwrote newer local copy.");
                Require(Clipboard.GetText() == "New Windows copy", "Local copy not preserved.");

                Require(OpenClipboard(window.Handle), "Test could not hold the clipboard.");
                try { Require(await UploadAsync(peer, id, "busy fixture", token) == "busy", "Busy clipboard did not fail boundedly."); }
                finally { CloseClipboard(); }
                await peer.SendAsync(new MouseMessage { Type = "ping" }, token); await peer.ExpectAsync("pong", token);
                Require(receiver.IsRunning, "Clipboard failure stopped receiver.");

                Require(await UploadAsync(peer, id, text, token) == "ok", "Retry failed.");
                await peer.SendAsync(new MouseMessage { Type = "enter", TransferId = id, CenterCursor = true }, token);
                await peer.ExpectAsync("entered", token);
                window.Activate(); box.Focus();
                var pasted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                box.TextChanged += (_, _) => { if (box.Text == Normalize(text)) pasted.TrySetResult(); };
                await peer.SendAsync(new MouseMessage { Type = "key", TransferId = id, Code = 55, Down = true }, token);
                await peer.SendAsync(new MouseMessage { Type = "key", TransferId = id, Code = 9, Down = true }, token);
                await peer.SendAsync(new MouseMessage { Type = "key", TransferId = id, Code = 9, Down = false }, token);
                await peer.SendAsync(new MouseMessage { Type = "key", TransferId = id, Code = 55, Down = false }, token);
                await pasted.Task.WaitAsync(TimeSpan.FromSeconds(3), token);
                await peer.SendAsync(new MouseMessage { Type = "leave", TransferId = id }, token);
                Console.WriteLine("PASS encrypted clipboard chunks, Unicode/long code, real Ctrl+V, local-copy conflict, busy retry, history opt-out");
                // The wire mapping is intentionally unchanged: Mac Command
                // is Ctrl. Verify repeated focus leases do not leave Ctrl/Win
                // down or turn the next paste into a Windows-logo shortcut.
                for (int cycle = 0; cycle < 12; cycle++)
                {
                    await peer.SendAsync(new MouseMessage { Type = "ping" }, token);
                    await peer.ExpectAsync("pong", token);
                    box.Clear(); window.Activate(); box.Focus();
                    string nextId = Guid.NewGuid().ToString();
                    await peer.SendAsync(new MouseMessage { Type = "prepare", TransferId = nextId }, token);
                    await peer.ExpectAsync("prepared", token);
                    await peer.SendAsync(new MouseMessage { Type = "enter", TransferId = nextId, CenterCursor = true }, token);
                    await peer.ExpectAsync("entered", token);
                    // A delayed key from the previous owner has no authority.
                    await peer.SendAsync(new MouseMessage { Type = "key", TransferId = id, Code = 59, Down = true }, token);
                    await peer.SendAsync(new MouseMessage { Type = "key", TransferId = nextId, Code = 55, Down = true }, token);
                    await peer.SendAsync(new MouseMessage { Type = "key", TransferId = nextId, Code = 9, Down = true }, token);
                    await peer.SendAsync(new MouseMessage { Type = "key", TransferId = nextId, Code = 9, Down = false }, token);
                    await peer.SendAsync(new MouseMessage { Type = "key", TransferId = nextId, Code = 55, Down = false }, token);
                    await peer.SendAsync(new MouseMessage { Type = "ping" }, token);
                    await peer.ExpectAsync("pong", token);
                    var deadline = Stopwatch.StartNew();
                    while ((box.Text != Normalize(text) || !ModifiersReleased()) && deadline.ElapsedMilliseconds < 1500)
                        await Task.Delay(10, token);
                    Require(box.Text == Normalize(text), $"Repeated paste failed at focus lease {cycle}.");
                    Require(ModifiersReleased(), $"A modifier remained down after paste at focus lease {cycle}.");
                    await peer.SendAsync(new MouseMessage { Type = "leave", TransferId = nextId }, token);
                    id = nextId;
                }
                Console.WriteLine("PASS 12 encrypted focus/paste/leave cycles; stale Windows-logo input rejected and native Ctrl/Alt/Shift/Win state released");
                result = 0;
            }
            catch (Exception error) { Console.Error.WriteLine("FAIL clipboard: " + error); }
            finally { Clipboard.Clear(); Native.SetCursorPos(original.X, original.Y); window.Close(); }
        };
        Application.Run(window);
        return result;
    }

    internal static MouseMessage[] Frames(string transfer, string text)
    {
        byte[] data = Encoding.UTF8.GetBytes(text);
        string id = Guid.NewGuid().ToString();
        var frames = new List<MouseMessage> { new() { Type = "clipboard-begin", TransferId = transfer,
            ClipboardId = id, ClipboardBytes = data.Length } };
        for (int offset = 0; offset < data.Length; offset += TextClipboardTransfer.ChunkBytes)
            frames.Add(new MouseMessage { Type = "clipboard-chunk", TransferId = transfer, ClipboardId = id,
                ClipboardIndex = offset / TextClipboardTransfer.ChunkBytes,
                ClipboardData = Convert.ToBase64String(data.AsSpan(offset, Math.Min(TextClipboardTransfer.ChunkBytes, data.Length - offset)))
                    .Replace('+', '-').Replace('/', '_') });
        frames.Add(new MouseMessage { Type = "clipboard-commit", TransferId = transfer, ClipboardId = id });
        return frames.ToArray();
    }
    internal static async Task<string?> UploadAsync(RemoteInputRegression.Peer peer, string transfer, string text, CancellationToken token)
    {
        foreach (var message in Frames(transfer, text)) await peer.SendAsync(message, token);
        var reply = await peer.ReadAsync(token);
        Require(reply.Type == "clipboard-result", "Missing clipboard acknowledgment.");
        return reply.Reason;
    }
    private static string Normalize(string text) => text.Replace("\r\n", "\n").Replace('\r', '\n').Replace("\n", "\r\n");
    private static void CheckAssembly()
    {
        string id = Guid.NewGuid().ToString();
        using var buffer = new TextClipboardTransfer();
        var frames = Frames(id, new string('\uffff', 15000));
        Require(buffer.Begin(frames[0], 0), "Valid begin rejected.");
        foreach (var frame in frames[1..^1])
        {
            Require(WireProtocol.Encrypt(frame, new byte[32], 0, true).Length <= 4100, "Chunk exceeded original wire limit.");
            Require(buffer.Append(frame), "Valid ordered chunk rejected.");
        }
        Require(buffer.Finish(frames[^1]) == new string('\uffff', 15000), "Chunk reconstruction failed.");
        frames[0].ClipboardBytes = TextClipboardTransfer.MaxBytes + 1;
        Require(!buffer.Begin(frames[0], 0), "Oversized allocation accepted.");
        frames = Frames(id, "abc"); buffer.Begin(frames[0], 0);
        Require(buffer.Finish(frames[^1]) is null, "Incomplete transfer committed.");
        buffer.Begin(frames[0], 0); buffer.Append(frames[1]);
        Require(!buffer.Append(frames[1]) && buffer.Finish(frames[^1]) is null, "Duplicate chunk accepted.");
        frames = Frames(id, "a\0b"); buffer.Begin(frames[0], 0); buffer.Append(frames[1]);
        Require(buffer.Finish(frames[^1]) is null, "Embedded NUL accepted.");
        frames = Frames(id, "abc"); buffer.Begin(frames[0], 0); frames[1].ClipboardData = "____";
        buffer.Append(frames[1]); Require(buffer.Finish(frames[^1]) is null, "Invalid UTF8 accepted.");
        buffer.Begin(frames[0], 0); frames[1].TransferId = Guid.NewGuid().ToString();
        Require(!buffer.Append(frames[1]), "Stale transfer accepted.");
        Console.WriteLine("PASS clipboard bounded assembly, stale/out-of-order/duplicate/incomplete/NUL/invalid-UTF8 rejection");
    }

    internal static string ReadFixtureText()
    {
        // CI-only native read also verifies SYSTEM writer -> normal test process.
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true") throw new InvalidOperationException();
        Require(OpenClipboard(0), "Fixture clipboard is unavailable.");
        try
        {
            nint memory = GetClipboardData(13), pointer = memory == 0 ? 0 : GlobalLock(memory);
            if (pointer == 0) throw new Exception("No fixture Unicode clipboard.");
            try { return Marshal.PtrToStringUni(pointer) ?? ""; }
            finally { GlobalUnlock(memory); }
        }
        finally { CloseClipboard(); }
    }
    private static void Require(bool condition, string failure) { if (!condition) throw new Exception(failure); }
    private static bool ModifiersReleased() => new[] { 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C }
        .All(key => (GetAsyncKeyState(key) & 0x8000) == 0);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern bool OpenClipboard(nint owner);
    [DllImport("user32.dll")] private static extern bool CloseClipboard();
    [DllImport("user32.dll")] private static extern nint GetClipboardData(uint format);
    [DllImport("kernel32.dll")] private static extern nint GlobalLock(nint memory);
    [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(nint memory);
    [DllImport("user32.dll")] private static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterClipboardFormatW(string name);
}

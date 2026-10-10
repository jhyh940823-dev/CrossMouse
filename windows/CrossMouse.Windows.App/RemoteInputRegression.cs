using System.Buffers.Binary;
using System.Diagnostics;
using System.Drawing;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

/// <summary>
/// Runs only when explicitly invoked by a self-test command. Uses an ephemeral
/// port and random key, never the user's pairing files. Unlike Form.Close(),
/// the caption test sends real encrypted mouse-down/up messages through the
/// production receiver and SendInput into the native Windows titlebar.
/// </summary>
internal static class RemoteInputRegression
{
    internal static int Run(bool clickCaption)
    {
        byte[] key = RandomNumberGenerator.GetBytes(32);
        using var window = new CrossMouseWindow(selfTestKey: key, port: 0);
        int result = 1;
        Native.GetCursorPos(out var originalPointer);
        // A UI timer cannot detect a stopped UI continuation. This watchdog
        // lives outside the Forms message loop and terminates ONLY this CI
        // self-test process if cleanup itself is unable to make progress.
        using var watchdog = new System.Threading.Timer(_ =>
        {
            Console.Error.WriteLine("FAIL remote input regression watchdog (30s)");
            Environment.Exit(1);
        }, null, TimeSpan.FromSeconds(30), Timeout.InfiniteTimeSpan);

        window.Shown += async (_, _) =>
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            Peer? peer = null;
            CaptionProbe? probe = null;
            try
            {
                peer = await Task.Run(() => Peer.ConnectAsync(
                    key, window.ListeningPortForTest, timeout.Token));
                if (clickCaption)
                {
                    probe = new CaptionProbe(window.Handle);
                    for (int attempt = 1; attempt <= 2; attempt++)
                    {
                        if (attempt > 1) window.RestoreForTest();
                        window.Activate();
                        Point closePoint = FindNativeCloseButton(window.Handle);
                        CaptionProbe activeProbe = probe;
                        Peer activePeer = peer;
                        await Task.Run(() => RemoteClickAsync(
                            activePeer, closePoint, activeProbe, attempt, timeout.Token));
                        // These are UI properties, so inspect them after
                        // returning to the actual UI thread, not in the peer.
                        if (window.Visible || window.IsDisposed || !window.ReceiverRunningForTest)
                            throw new Exception("Native remote X did not hide a live receiver window.");
                        Console.WriteLine($"PASS native remote X #{attempt}: hidden, TCP live");

                        await Task.Run(async () =>
                        {
                            await activePeer.SendAsync(new MouseMessage
                                { Type = "enter", FractionY = 0.5 }, timeout.Token);
                            await activePeer.ExpectAsync("entered", timeout.Token);
                            await activePeer.SendAsync(new MouseMessage
                                { Type = "ping" }, timeout.Token);
                            await activePeer.ExpectAsync("pong", timeout.Token);
                            await activePeer.SendAsync(new MouseMessage
                                { Type = "leave" }, timeout.Token);
                        });
                    }
                    Console.WriteLine("PASS encrypted native down/up, hidden re-entry, second remote X");
                }
                else
                {
                    var begin = new TaskCompletionSource(
                        TaskCreationOptions.RunContinuationsAsynchronously);
                    Peer activePeer = peer;
                    Task response = Task.Run(async () =>
                    {
                        await begin.Task.ConfigureAwait(false);
                        await activePeer.SendAsync(new MouseMessage { Type = "ping" }, timeout.Token);
                        await activePeer.ExpectAsync("pong", timeout.Token);
                    });
                    // Deliberately stop pumping this test's UI. Independent
                    // input/network work must NOT require its SynchronizationContext.
                    begin.SetResult();
                    var elapsed = Stopwatch.StartNew();
                    bool completedWithoutUI = response.Wait(TimeSpan.FromSeconds(1.5));
                    Console.WriteLine($"UI withheld; receiver pong within 1500ms: {completedWithoutUI}; elapsed={elapsed.ElapsedMilliseconds}ms");
                    if (!completedWithoutUI)
                        throw new Exception("Receiver heartbeat depends on the Windows UI message loop.");
                    await response;
                    Console.WriteLine("PASS receiver continues while UI is not pumping");
                }
                result = 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine($"FAIL {(clickCaption ? "native caption" : "UI independence")}: {error}");
            }
            finally
            {
                timeout.Cancel();
                peer?.Dispose();
                // Release native caption tracking even in the OLD buggy build,
                // without depending on its receiver, lock, or Forms context.
                await Task.Run(() => Native.MouseButton(0, down: false));
                probe?.ReleaseHandle();
                try { await window.QuitForTestAsync(); }
                catch (Exception error)
                {
                    result = 1;
                    Console.Error.WriteLine($"FAIL regression cleanup: {error}");
                }
                Native.SetCursorPos(originalPointer.X, originalPointer.Y);
                Application.ExitThread();
            }
        };
        Application.Run(window);
        return result;
    }

    private static async Task RemoteClickAsync(
        Peer peer, Point target, CaptionProbe probe, int attempt, CancellationToken token)
    {
        // All network traffic and waits originate outside the UI thread.
        await peer.SendAsync(new MouseMessage { Type = "enter", FractionY = 0.5 }, token);
        await peer.ExpectAsync("entered", token);
        if (!Native.GetCursorPos(out var current)) throw new Exception("No Windows cursor.");
        await peer.SendAsync(new MouseMessage
        {
            Type = "move", Dx = target.X - current.X, Dy = target.Y - current.Y
        }, token);
        var moved = Stopwatch.StartNew();
        while (true)
        {
            if (Native.GetCursorPos(out current) &&
                Math.Abs(current.X - target.X) <= 1 && Math.Abs(current.Y - target.Y) <= 1) break;
            if (moved.Elapsed > TimeSpan.FromSeconds(2))
                throw new Exception("Remote cursor did not reach the verified native X hit target.");
            await Task.Delay(10, token).ConfigureAwait(false);
        }

        try
        {
            await peer.SendAsync(new MouseMessage { Type = "button", Button = 0, Down = true }, token);
            var downWait = Stopwatch.StartNew();
            while (probe.DownCount < attempt)
            {
                if (downWait.Elapsed > TimeSpan.FromSeconds(2))
                    throw new Exception("Encrypted mouse-down did not reach WM_NCLBUTTONDOWN/HTCLOSE.");
                await Task.Delay(10, token).ConfigureAwait(false);
            }
            Console.WriteLine($"Native caption #{attempt}: WM_NCLBUTTONDOWN/HTCLOSE observed");
            await Task.Delay(100, token).ConfigureAwait(false);
            await peer.SendAsync(new MouseMessage { Type = "button", Button = 0, Down = false }, token);
            using var replyTimeout = CancellationTokenSource.CreateLinkedTokenSource(token);
            replyTimeout.CancelAfter(TimeSpan.FromSeconds(2.5));
            await peer.ExpectAsync("leave", replyTimeout.Token);
        }
        finally
        {
            // Test cleanup only; production remote input must deliver its own
            // mouse-up. If it could not, the test has already failed above.
            Native.MouseButton(0, down: false);
        }
    }

    private sealed class CaptionProbe : NativeWindow
    {
        private int _downCount;
        internal int DownCount => Volatile.Read(ref _downCount);
        internal CaptionProbe(nint handle) => AssignHandle(handle);
        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x00A1 && message.WParam == 20) // WM_NCLBUTTONDOWN / HTCLOSE
                Interlocked.Increment(ref _downCount);
            base.WndProc(ref message);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(nint window, out Rect rect);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint SendMessageW(nint window, uint message, nuint wParam, nint lParam);

    private static Point FindNativeCloseButton(nint handle)
    {
        if (!GetWindowRect(handle, out var rect)) throw new Exception("No native window bounds.");
        // Verify the native HTCLOSE hit test instead of assuming DPI, theme,
        // or a fixed caption size. This code runs on the owning UI thread.
        for (int y = rect.Top + 8; y < rect.Top + 70; y += 3)
        for (int x = rect.Right - 12; x > rect.Right - 100; x -= 3)
        {
            int packed = ((y & 0xffff) << 16) | (x & 0xffff);
            if (SendMessageW(handle, 0x0084, 0, (nint)packed) == 20)
                return new Point(x, y);
        }
        throw new Exception("Native X hit target (HTCLOSE) unavailable; not silently skipping.");
    }

    private sealed class Peer : IDisposable
    {
        private readonly TcpClient _client;
        private readonly byte[] _sessionKey;
        private ulong _sendSequence, _receiveSequence;
        private Peer(TcpClient client, byte[] key) { _client = client; _sessionKey = key; }

        internal static async Task<Peer> ConnectAsync(byte[] key, int port, CancellationToken token)
        {
            var client = new TcpClient { NoDelay = true };
            try
            {
                await client.ConnectAsync(IPAddress.Loopback, port, token).ConfigureAwait(false);
                var stream = client.GetStream();
                byte[] nonce = RandomNumberGenerator.GetBytes(16);
                await stream.WriteAsync(WireProtocol.ClientHello(key, nonce), token).ConfigureAwait(false);
                var hello = new byte[WireProtocol.HelloLength];
                await stream.ReadExactlyAsync(hello, token).ConfigureAwait(false);
                if (!WireProtocol.VerifyServerHello(hello, key, nonce, out var serverNonce))
                    throw new Exception("Regression peer authentication failed.");
                var peer = new Peer(client, WireProtocol.SessionKey(key, nonce, serverNonce));
                await peer.SendAsync(new MouseMessage { Type = "ping" }, token);
                await peer.ExpectAsync("pong", token);
                return peer;
            }
            catch { client.Dispose(); throw; }
        }

        internal async Task SendAsync(MouseMessage message, CancellationToken token)
        {
            byte[] frame = WireProtocol.Encrypt(message, _sessionKey, _sendSequence++, fromMac: true);
            await _client.GetStream().WriteAsync(frame, token).ConfigureAwait(false);
        }

        internal async Task ExpectAsync(string type, CancellationToken token)
        {
            var stream = _client.GetStream();
            var header = new byte[4];
            await stream.ReadExactlyAsync(header, token).ConfigureAwait(false);
            int length = BinaryPrimitives.ReadInt32BigEndian(header);
            if (length < 16 || length > WireProtocol.MaxFrameLength) throw new Exception("Invalid frame length.");
            var payload = new byte[length];
            await stream.ReadExactlyAsync(payload, token).ConfigureAwait(false);
            var reply = WireProtocol.Decrypt(payload, _sessionKey, _receiveSequence++, fromMac: false);
            if (reply.Type != type) throw new Exception($"Expected {type}, received {reply.Type}.");
        }

        public void Dispose() => _client.Dispose();
    }
}

using System.Windows.Forms;
using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains("--service-self-test"))
        {
            // Windows CI smoke test: bind the real listener, authenticate
            // locally, verify the reply and stop without injecting input.
            try
            {
                ServiceSelfTest().GetAwaiter().GetResult();
                return 0;
            }
            catch (Exception error)
            {
                System.Diagnostics.Debug.WriteLine($"Receiver smoke test failed: {error}");
                return 1;
            }
        }
        ApplicationConfiguration.Initialize();
        if (args.Contains("--gui-self-test"))
            return GuiLifetimeSelfTest();
        Application.Run(new CrossMouseWindow());
        return 0;
    }

    private static int GuiLifetimeSelfTest()
    {
        // Exercise the real Windows Forms lifetime and its production receiver.
        // A protocol-only smoke test cannot catch Close() killing the hidden
        // tray app and disconnecting the user's mouse.
        var secret = RandomNumberGenerator.GetBytes(32);
        using var window = new CrossMouseWindow(selfTestKey: secret, port: 0);
        int result = 1;
        int closedEvents = 0;
        window.FormClosed += (_, _) => closedEvents++;
        using var watchdog = new System.Windows.Forms.Timer { Interval = 15_000 };
        watchdog.Tick += (_, _) =>
        {
            watchdog.Stop();
            System.Diagnostics.Debug.WriteLine("GUI lifetime smoke test timed out.");
            Application.ExitThread();
        };
        window.Shown += async (_, _) =>
        {
            try
            {
                if (!window.ReceiverRunningForTest || window.ListeningPortForTest == 0)
                    throw new Exception("GUI failed to start receiver.");

                // Simulate a REAL Mac actively controlling the Windows cursor
                // and clicking X on the GUI from that remote session. Earlier
                // CI only checked X while no remote mouse was present, which
                // missed the user's cursor-trap failure.
                using (var client = new TcpClient())
                using (var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5)))
                {
                    await client.ConnectAsync(
                        IPAddress.Loopback, window.ListeningPortForTest, timeout.Token
                    );
                    var stream = client.GetStream();
                    var nonce = RandomNumberGenerator.GetBytes(16);
                    await stream.WriteAsync(WireProtocol.ClientHello(secret, nonce), timeout.Token);
                    var hello = new byte[WireProtocol.HelloLength];
                    await stream.ReadExactlyAsync(hello, timeout.Token);
                    if (!WireProtocol.VerifyServerHello(hello, secret, nonce, out var serverNonce))
                        throw new Exception("Remote input test handshake failed.");
                    var sessionKey = WireProtocol.SessionKey(secret, nonce, serverNonce);
                    var enter = WireProtocol.Encrypt(
                        new MouseMessage { Type = "enter", FractionY = 0.5 },
                        sessionKey, sequence: 0, fromMac: true
                    );
                    await stream.WriteAsync(enter, timeout.Token);
                    for (int i = 0; i < 100 && !window.RemoteActiveForTest; i++)
                        await Task.Delay(10, timeout.Token);
                    if (!window.RemoteActiveForTest)
                        throw new Exception("Receiver did not enter remote mouse mode.");

                    // X must hide the window and RELEASE the captured Mac
                    // input, while keeping the server accepting connections.
                    window.Close();
                    if (window.Visible || window.IsDisposed || closedEvents != 0 ||
                        !window.ReceiverRunningForTest)
                        throw new Exception("Window X closed or stopped the input receiver.");
                    var frameSize = new byte[4];
                    await stream.ReadExactlyAsync(frameSize, timeout.Token);
                    int length = BinaryPrimitives.ReadInt32BigEndian(frameSize);
                    if (length < 16 || length > WireProtocol.MaxFrameLength)
                        throw new Exception("Return-to-Mac frame size invalid.");
                    var payload = new byte[length];
                    await stream.ReadExactlyAsync(payload, timeout.Token);
                    var returned = WireProtocol.Decrypt(
                        payload, sessionKey, sequence: 0, fromMac: false
                    );
                    if (returned.Type != "leave" || window.RemoteActiveForTest)
                        throw new Exception("X did not send authenticated leave and free Mac.");

                    // The same encrypted session must still be usable while
                    // the window remains hidden. Re-enter Windows and close
                    // the RESTORED window from within another active session.
                    var enterAgain = WireProtocol.Encrypt(
                        new MouseMessage { Type = "enter", FractionY = 0.5 },
                        sessionKey, sequence: 1, fromMac: true
                    );
                    await stream.WriteAsync(enterAgain, timeout.Token);
                    for (int i = 0; i < 100 && !window.RemoteActiveForTest; i++)
                        await Task.Delay(10, timeout.Token);
                    if (!window.RemoteActiveForTest)
                        throw new Exception("Hidden Windows app could not re-enter mouse mode.");
                    window.RestoreForTest();
                    if (!window.Visible || window.IsDisposed)
                        throw new Exception("The tray could not restore the GUI window.");
                    window.Close();
                    if (window.Visible || window.IsDisposed || closedEvents != 0 ||
                        !window.ReceiverRunningForTest)
                        throw new Exception("Closing restored GUI stopped its receiver.");
                    await stream.ReadExactlyAsync(frameSize, timeout.Token);
                    length = BinaryPrimitives.ReadInt32BigEndian(frameSize);
                    if (length < 16 || length > WireProtocol.MaxFrameLength)
                        throw new Exception("Second return-to-Mac frame size invalid.");
                    payload = new byte[length];
                    await stream.ReadExactlyAsync(payload, timeout.Token);
                    returned = WireProtocol.Decrypt(
                        payload, sessionKey, sequence: 1, fromMac: false
                    );
                    if (returned.Type != "leave" || window.RemoteActiveForTest)
                        throw new Exception("Closing restored GUI did not free Mac input.");
                }

                await CheckLoopbackHandshake(secret, window.ListeningPortForTest);
                if (!window.ReceiverRunningForTest)
                    throw new Exception("GUI receiver stopped during hidden connection.");

                window.RestoreForTest();
                if (!window.Visible || window.IsDisposed)
                    throw new Exception("The tray could not restore the GUI window.");
                window.Close();
                if (window.Visible || closedEvents != 0 || !window.ReceiverRunningForTest)
                    throw new Exception("Closing the restored window stopped background mode.");

                // Explicit Exit must do the opposite: release the port and
                // dispose the window and tray icon.
                await window.QuitForTestAsync();
                if (window.ReceiverRunningForTest || closedEvents != 1)
                    throw new Exception("Explicit Exit did not shut down the receiver.");
                result = 0;
                Console.WriteLine("PASS GUI active-remote X returns Mac, receiver alive, restore, Exit");
            }
            catch (Exception error)
            {
                Console.Error.WriteLine($"FAIL GUI lifetime smoke test: {error}");
                try { await window.QuitForTestAsync(); }
                catch (Exception shutdownError)
                {
                    Console.Error.WriteLine($"GUI test cleanup failed: {shutdownError}");
                }
            }
            finally
            {
                watchdog.Stop();
                Application.ExitThread();
            }
        };
        watchdog.Start();
        Application.Run(window);
        return result;
    }

    private static async Task ServiceSelfTest()
    {
        byte[] secret = RandomNumberGenerator.GetBytes(32);
        await using var server = new ReceiverService(secret, port: 0);
        server.Start();
        int port = server.ListeningPort;
        if (port is < 1 or > 65535) throw new Exception("Receiver did not bind.");
        await CheckLoopbackHandshake(secret, port);
        await server.StopAsync();
        if (server.IsRunning) throw new Exception("Receiver did not stop.");
    }

    private static async Task CheckLoopbackHandshake(byte[] secret, int port)
    {
        using var client = new TcpClient();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await client.ConnectAsync(IPAddress.Loopback, port, timeout.Token);
        var stream = client.GetStream();
        byte[] nonce = RandomNumberGenerator.GetBytes(16);
        await stream.WriteAsync(WireProtocol.ClientHello(secret, nonce), timeout.Token);
        byte[] hello = new byte[WireProtocol.HelloLength];
        await stream.ReadExactlyAsync(hello, timeout.Token);
        if (!WireProtocol.VerifyServerHello(hello, secret, nonce, out _))
            throw new Exception("Receiver handshake was not authenticated.");
    }
}

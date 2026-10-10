using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using CrossMouse.Windows;

if (args.Contains("--self-test"))
{
    SelfTest.Run();
    return;
}
if (!OperatingSystem.IsWindows())
{
    Console.Error.WriteLine("CrossMouse.Windows input receiver must run on Windows.");
    return;
}
if (args.Contains("--help") || args.Contains("-h"))
{
    Console.WriteLine("CrossMouse.Windows [--port 49431] [--key-file PATH] [--self-test]");
    return;
}

string? Argument(string flag)
{
    int at = Array.IndexOf(args, flag);
    return at >= 0 && at + 1 < args.Length ? args[at + 1] : null;
}

if (!int.TryParse(Argument("--port") ?? "49431", out int port) || port is < 1 or > 65535)
{
    Console.Error.WriteLine("Port must be between 1 and 65535.");
    return;
}
string directory = Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CrossMouse"
);
string keyPath = Argument("--key-file") ?? Path.Combine(directory, "key");
byte[] secret;
try
{
    if (!File.Exists(keyPath))
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(keyPath))!);
        string newKey = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
        // Per-user AppData directory inherits the current Windows user's ACL.
        using (var stream = new FileStream(keyPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        using (var writer = new StreamWriter(stream))
        {
            writer.WriteLine(newKey);
        }
        Console.WriteLine("NEW PAIRING KEY (copy this once to your Mac):");
        Console.WriteLine(newKey);
        Console.WriteLine();
    }
    secret = Convert.FromHexString(File.ReadAllText(keyPath).Trim());
    if (secret.Length != 32) throw new InvalidDataException("Expected a 64-character key.");
}
catch (Exception error)
{
    Console.Error.WriteLine($"Pairing key error: {error.Message}");
    return;
}

_ = Native.SetProcessDPIAware();
using var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) =>
{
    eventArgs.Cancel = true;
    cancellation.Cancel();
};

var listener = new TcpListener(IPAddress.Any, port);
listener.Start(backlog: 1);
Console.WriteLine($"CrossMouse receiver listening on TCP port {port}.");
Console.WriteLine($"Pairing key file: {keyPath}");
Console.WriteLine("Use ipconfig to find this PC's IPv4 address.");
Console.WriteLine("Windows Firewall may ask you to allow access on your private network.");
Console.WriteLine("Press Ctrl+C to stop.");

var injector = new InputInjector();
try
{
    while (!cancellation.IsCancellationRequested)
    {
        using TcpClient client = await listener.AcceptTcpClientAsync(cancellation.Token);
        client.NoDelay = true;
        try
        {
            await using var channel = await SecureChannel.AcceptAsync(
                client.GetStream(), secret, cancellation.Token
            );
            Console.WriteLine($"Paired Mac connected ({client.Client.RemoteEndPoint}).");
            using var sessionCancel = CancellationTokenSource.CreateLinkedTokenSource(cancellation.Token);
            var poll = PollForReturnAsync(injector, channel, sessionCancel.Token);
            try
            {
                while (!sessionCancel.Token.IsCancellationRequested)
                {
                    MouseMessage message = await channel.ReadAsync(sessionCancel.Token);
                    injector.Apply(message);
                }
            }
            finally
            {
                sessionCancel.Cancel();
                try { await poll; } catch (OperationCanceledException) { }
                injector.ReleaseAll();
            }
        }
        catch (Exception error) when (
            error is IOException or CryptographicException or OperationCanceledException
            or InvalidDataException or System.Text.Json.JsonException
        )
        {
            if (!cancellation.IsCancellationRequested)
                Console.WriteLine($"Client disconnected/rejected: {error.Message}");
            injector.ReleaseAll();
        }
    }
}
catch (OperationCanceledException)
{
    // Normal Ctrl+C shutdown.
}
finally
{
    injector.ReleaseAll();
    listener.Stop();
}

static async Task PollForReturnAsync(
    InputInjector injector, SecureChannel channel, CancellationToken cancellationToken
)
{
    while (!cancellationToken.IsCancellationRequested)
    {
        await Task.Delay(16, cancellationToken);
        if (injector.ReachedLeftEdge())
        {
            await channel.SendAsync(new MouseMessage { Type = "leave" }, cancellationToken);
        }
    }
}

internal static class SelfTest
{
    public static void Run()
    {
        byte[] secret = Enumerable.Range(0, 32).Select(n => (byte)n).ToArray();
        byte[] clientNonce = Enumerable.Range(0, 16).Select(n => (byte)n).ToArray();
        byte[] serverNonce = Enumerable.Range(16, 16).Select(n => (byte)n).ToArray();
        byte[] clientHello = WireProtocol.ClientHello(secret, clientNonce);
        Check(
            clientHello.AsSpan(20).SequenceEqual(Convert.FromHexString(
                "3682ada3f76c1cc5f061a4f57cb12967e11876f06627af8befede33f9bfdec3a")),
            "Client HMAC fixture"
        );
        Check(WireProtocol.VerifyClientHello(clientHello, secret, out var clientRead) &&
              clientRead.SequenceEqual(clientNonce), "Client authentication");
        byte[] serverHello = WireProtocol.ServerHello(secret, clientNonce, serverNonce);
        Check(WireProtocol.VerifyServerHello(serverHello, secret, clientNonce, out var serverRead) &&
              serverRead.SequenceEqual(serverNonce), "Server authentication");
        byte[] expectedKey = Convert.FromHexString(
            "7fe924fb2373ff3980cb7b713cbbf28e52553a739895eade120f7492a26e792d");
        byte[] key = WireProtocol.SessionKey(secret, clientNonce, serverNonce);
        Check(key.SequenceEqual(expectedKey), "Session key fixture");
        var frame = WireProtocol.Encrypt(new MouseMessage { Type = "key", Code = 55, Down = true },
            key, 7, fromMac: true);
        Check(Convert.ToHexString(frame).Equals(
            "00000034B24CA63A9487C156DF44E1D997B1C4AF6874F3D6E2AF3CEFB4832C539D610BCA6C73641EF6F86FC9BD340A43E05C25D0F8FB6D34",
            StringComparison.OrdinalIgnoreCase), "Cross-language encrypted frame fixture");
        var decoded = WireProtocol.Decrypt(frame.AsSpan(4), key, 7, fromMac: true);
        Check(decoded.Type == "key" && decoded.Code == 55 && decoded.Down == true,
            "AES-GCM roundtrip");
        bool rejected = false;
        try { _ = WireProtocol.Decrypt(frame.AsSpan(4), key, 8, fromMac: true); }
        catch (CryptographicException) { rejected = true; }
        Check(rejected, "Reject replay/wrong sequence");
        rejected = WireProtocol.VerifyClientHello(clientHello,
            Enumerable.Repeat((byte)9, 32).ToArray(), out _);
        Check(!rejected, "Reject incorrect pairing key");
        Check(KeyMapping.TryGet(55, out int control) && control == 0x1D, "Mac Cmd to Ctrl");
        Check(KeyMapping.TryGet(123, out int left) && left == 0x14B, "Extended left arrow");
        TestMouseSmoothing();
        Console.WriteLine("PASS CrossMouse protocol self-tests");
    }

    private static void TestMouseSmoothing()
    {
        var motion = new MotionSmoother();
        motion.Add(120, -75);
        var first = motion.Step();
        Check(first.Dx is > 0 and < 120 && first.Dy is < 0 and > -75,
            "Batched movement is spread over render ticks");
        int sumX = first.Dx, sumY = first.Dy;
        for (int i = 0; i < 12 && motion.HasPending; i++)
        {
            var delta = motion.Step();
            Check(delta.Dx >= 0 && delta.Dy <= 0, "No smoothing overshoot");
            sumX += delta.Dx;
            sumY += delta.Dy;
        }
        Check(!motion.HasPending && sumX == 120 && sumY == -75,
            "Smoothed movement conserves precise total distance");

        // A burst of mouse packets in one scheduling interval cannot become
        // a single giant cursor jump. A click drains the remaining distance.
        motion.Reset();
        for (int i = 0; i < 10; i++) motion.Add(15, -2);
        var burst = motion.Step();
        Check(burst.Dx is > 0 and < 150, "Jitter burst is interpolated");
        var rest = motion.Drain();
        Check(burst.Dx + rest.Dx == 150 && burst.Dy + rest.Dy == -20,
            "Click-time drain preserves movement ordering");
        Check(!motion.HasPending, "Drain clears remaining movement");

        motion.Add(200, 40);
        motion.Reset();
        Check(!motion.HasPending && motion.Step() == (0, 0),
            "Leaving Windows discards pending motion");

        motion.Add(800, 0);
        for (int i = 0; i < 30 && motion.HasPending; i++) motion.Step();
        Check(!motion.HasPending, "Large bursts settle within bounded ticks");
    }

    private static void Check(bool condition, string name)
    {
        if (!condition) throw new Exception($"FAIL: {name}");
    }
}

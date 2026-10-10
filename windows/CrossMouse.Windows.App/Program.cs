using System.Windows.Forms;
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
        Application.Run(new CrossMouseWindow());
        return 0;
    }

    private static async Task ServiceSelfTest()
    {
        byte[] secret = RandomNumberGenerator.GetBytes(32);
        await using var server = new ReceiverService(secret, port: 0);
        server.Start();
        int port = server.ListeningPort;
        if (port is < 1 or > 65535) throw new Exception("Receiver did not bind.");
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
        await server.StopAsync();
        if (server.IsRunning) throw new Exception("Receiver did not stop.");
    }
}

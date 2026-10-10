using System.Diagnostics;
using System.Security.Cryptography;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

/// <summary>
/// Real encrypted loopback connections, random temporary pairing key and port.
/// No user's service, pairing files, login state, display input or ordinary keys
/// are touched. A connected TCP socket is deliberately left open while silent.
/// </summary>
internal static class PeerLeaseRegression
{
    internal static int Run()
    {
        using var watchdog = new System.Threading.Timer(_ =>
        {
            Console.Error.WriteLine("FAIL peer lease watchdog (40s)");
            Environment.Exit(1);
        }, null, TimeSpan.FromSeconds(40), Timeout.InfiniteTimeSpan);
        try { CheckAsync().GetAwaiter().GetResult(); return 0; }
        catch (Exception error) { Console.Error.WriteLine($"FAIL peer lease: {error}"); return 1; }
    }

    private static async Task CheckAsync()
    {
        byte[] key = RandomNumberGenerator.GetBytes(32);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(35));
        var token = timeout.Token;
        bool restoreCursor = Native.GetCursorPos(out var original);
        await using var receiver = new ReceiverService(key, 0);
        receiver.Start();
        try
        {
            // Keep sending authenticated heartbeats longer than the lease. An
            // intentionally stationary mouse is NOT a dead network connection.
            using (var peer = await RemoteInputRegression.Peer.ConnectAsync(key, receiver.ListeningPort, token))
            {
                await peer.SendAsync(new MouseMessage { Type = "enter", CenterCursor = true }, token);
                await peer.ExpectAsync("entered", token);
                for (int i = 0; i < 24; i++)
                {
                    await Task.Delay(250, token);
                    await peer.SendAsync(new MouseMessage { Type = "ping" }, token);
                    await peer.ExpectAsync("pong", token);
                    Require(receiver.IsRemotelyActive, "A stationary but live peer lost control.");
                }
                Console.WriteLine("PASS idle mouse with authenticated heartbeat retains input for 6s");

                // Nothing is sent and this client's socket remains open. Old
                // code waited for TCP indefinitely, retaining ownership and the
                // single-listener slot. This must now have bounded cleanup.
                var silence = Stopwatch.StartNew();
                while (receiver.IsRemotelyActive && silence.Elapsed < TimeSpan.FromSeconds(7))
                    await Task.Delay(25, token);
                Require(!receiver.IsRemotelyActive, "Silent connected peer retained input beyond 7s.");
                Require(receiver.IsRunning, "Peer expiry stopped the listener instead of just its session.");
                Console.WriteLine($"PASS silent OPEN TCP peer released input after {silence.ElapsedMilliseconds}ms");

                // Reconnect while the first client is STILL alive. This verifies
                // that ownership cleanup also relinquished the receiver slot.
                using var next = await RemoteInputRegression.Peer.ConnectAsync(key, receiver.ListeningPort, token);
                await next.SendAsync(new MouseMessage { Type = "ping" }, token);
                await next.ExpectAsync("pong", token);
                Console.WriteLine("PASS next authenticated client connects before old client is disposed");
            }

            // A prefix is not authenticated input. Incomplete/encrypted junk
            // must not renew the lease or block the listener forever.
            using (var partial = await RemoteInputRegression.Peer.ConnectAsync(key, receiver.ListeningPort, token))
            {
                await partial.SendAsync(new MouseMessage { Type = "enter", CenterCursor = true }, token);
                await partial.ExpectAsync("entered", token);
                await partial.WriteIncompleteFrameForTestAsync(token);
                var silence = Stopwatch.StartNew();
                while (receiver.IsRemotelyActive && silence.Elapsed < TimeSpan.FromSeconds(7))
                    await Task.Delay(25, token);
                Require(!receiver.IsRemotelyActive, "Incomplete frame indefinitely retained input.");
                using var next = await RemoteInputRegression.Peer.ConnectAsync(key, receiver.ListeningPort, token);
                await next.SendAsync(new MouseMessage { Type = "ping" }, token);
                await next.ExpectAsync("pong", token);
                Console.WriteLine("PASS incomplete frame does not extend lease; authenticated reconnect succeeds");
            }
        }
        finally
        {
            await receiver.StopAsync();
            if (restoreCursor) Native.SetCursorPos(original.X, original.Y);
            CryptographicOperations.ZeroMemory(key);
        }
    }

    private static void Require(bool condition, string message)
    { if (!condition) throw new Exception(message); }
}

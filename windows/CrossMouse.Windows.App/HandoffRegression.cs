using System.Runtime.InteropServices;
using System.Security.Cryptography;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

internal static class HandoffRegression
{
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    internal static int Run()
    {
        try { CheckAsync().GetAwaiter().GetResult(); return 0; }
        catch (Exception error) { Console.Error.WriteLine($"FAIL ownership handshake: {error}"); return 1; }
    }
    private static async Task CheckAsync()
    {
        Native.GetCursorPos(out var original);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        var token = deadline.Token;
        var secret = RandomNumberGenerator.GetBytes(32);
        await using var receiver = new ReceiverService(secret, 0);
        receiver.Start();
        try
        {
            using var peer = await RemoteInputRegression.Peer.ConnectAsync(secret, receiver.ListeningPort, token);
            await peer.SendAsync(new MouseMessage { Type = "ping" }, token);
            var capability = await peer.ReadAsync(token);
            Require(capability.Type == "pong" && capability.Capability == "handoff-2", "missing explicit capability");

            string previous = Guid.NewGuid().ToString();
            string current = Guid.NewGuid().ToString();
            await Prepare(peer, previous, token);
            Require(!receiver.IsRemotelyActive, "preparation captured user input");
            await peer.SendAsync(new MouseMessage { Type="leave", TransferId=previous }, token);
            await peer.SendAsync(new MouseMessage { Type="ping" }, token); await peer.ExpectAsync("pong", token);
            await Prepare(peer, current, token);
            Require(!receiver.IsRemotelyActive, "second preparation captured input");
            await peer.SendAsync(new MouseMessage { Type="enter", TransferId=current, CenterCursor=true }, token);
            var entered = await peer.ReadAsync(token);
            Require(entered.Type == "entered" && entered.TransferId == current && entered.PointerVisible == true,
                $"entry not visibly acknowledged: {entered.Type}/{entered.Reason}");
            Require(receiver.IsRemotelyActive, "receiver did not acquire input");
            Console.WriteLine("PASS prepare leaves Mac ownership; target + presentation acknowledged before ownership");

            Native.GetCursorPos(out var centered);
            await peer.SendAsync(new MouseMessage { Type="leave", TransferId=previous }, token);
            await peer.SendAsync(new MouseMessage { Type="move", TransferId=previous, Dx=-2000, Dy=0 }, token);
            await peer.SendAsync(new MouseMessage { Type="ping" }, token); await peer.ExpectAsync("pong", token);
            await Task.Delay(80, token);
            Native.GetCursorPos(out var afterStale);
            Require(receiver.IsRemotelyActive && centered.X == afterStale.X && centered.Y == afterStale.Y,
                "previous epoch affected the current owner");
            Console.WriteLine("PASS old leave and old motion cannot release/move the new session");

            for (int tick=0; tick<6; tick++)
            {
                await Task.Delay(250, token);
                await peer.SendAsync(new MouseMessage { Type="ping" }, token); await peer.ExpectAsync("pong", token);
                Require(receiver.IsRemotelyActive, "idle incorrectly released ownership");
            }
            await peer.SendAsync(new MouseMessage { Type="move", TransferId=current, Dx=-2048, Dy=0 }, token);
            var leave = await peer.ReadAsync(token);
            Require(leave.Type == "leave" && leave.TransferId == current && leave.Reason == "left-edge",
                "return not identified with owner and actual reason");
            Console.WriteLine("PASS idle preserved; actual left move returns with matching ID/reason");

            bool active = true;
            nint foreground = GetForegroundWindow();
            using var presenter = new PointerPresenter(() => active, simulateHiddenNativePointerForTest: true);
            Require(await presenter.VerifyAsync(token), "no physical/native cursor fallback not presented");
            Require(GetForegroundWindow() == foreground, "pointer presentation stole focus");
            active = false;
            Require(!await presenter.VerifyAsync(token), "pointer surface remained after ownership ended");
            Console.WriteLine("PASS simulated missing native cursor has click-through presentation; no activation; release hides it");
        }
        finally { await receiver.StopAsync(); Native.SetCursorPos(original.X, original.Y); }
    }
    private static async Task Prepare(RemoteInputRegression.Peer peer, string id, CancellationToken token)
    {
        await peer.SendAsync(new MouseMessage { Type="prepare", TransferId=id }, token);
        var reply = await peer.ReadAsync(token);
        Require(reply.Type == "prepared" && reply.TransferId == id, $"prepare failed: {reply.Type}/{reply.Reason}");
    }
    private static void Require(bool value, string failure) { if (!value) throw new Exception(failure); }
}

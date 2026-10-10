using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

internal enum ReceiverState { Stopped, Waiting, Connected, Faulted }

/// <summary>
/// Starts and stops the same encrypted receiver as the original console app.
/// No input is accepted without successful pairing. A stopped or disconnected
/// receiver releases every pressed key and button.
/// </summary>
internal sealed class ReceiverService : IAsyncDisposable
{
    private readonly byte[] _key;
    private readonly int _port;
    private readonly bool _rejectLocalPeers;
    private readonly InputInjector _injector = new(smoothMotion: true);
    private TcpListener? _listener;
    private TcpClient? _activeClient;
    private SecureChannel? _activeChannel;
    private CancellationTokenSource? _cancel;
    private Task? _loop;
    private const string HandoffCapability = "handoff-2";
    // Mac sends an authenticated heartbeat every 500ms even when the mouse is
    // stationary. Bound ownership by peer liveness, not by cursor movement or
    // TCP's potentially very long half-open connection detection.
    private static readonly TimeSpan PeerSilenceLimit = TimeSpan.FromSeconds(5);
    private readonly object _handoff = new();
    private string? _preparedId, _activeId;
    private TargetDisplay? _target;
    private CancellationTokenSource? _activationCancel;
    private Task? _activation;
    private PointerPresenter? _presenter;

    public event Action<ReceiverState, string>? StatusChanged;

    public ReceiverService(byte[] key, int port = 49431, bool rejectLocalPeers = false)
    {
        if (key.Length != 32) throw new ArgumentException("Invalid pairing key.", nameof(key));
        _key = key;
        _port = port;
        _rejectLocalPeers = rejectLocalPeers;
    }

    public bool IsRunning => _listener is not null;
    public bool IsRemotelyActive => _injector.IsRemotelyActive;
    public string? InputFailure => _injector.InputFailure;
    public int ListeningPort =>
        (_listener?.LocalEndpoint as IPEndPoint)?.Port ?? 0;

    public void SetSmoothingEnabled(bool enabled) => _injector.SetSmoothingEnabled(enabled);

    public InputInjector.MotionGapStats TakeMotionGapStats() => _injector.TakeMotionGapStats();

    /// <summary>
    /// Called when the user closes the GUI while controlling Windows from
    /// their Mac. Hiding the last Windows app window must never leave their
    /// physical mouse trapped on Windows. Return Mac control but keep the
    /// listener running, so moving to the edge can enter Windows again.
    /// Do not rely on a Window Forms UI thread to keep the remote pointer
    /// usable after the last visible form is hidden.
    /// </summary>
    public async Task ReturnCursorToMacAsync()
    {
        string? id;
        SecureChannel? channel;
        lock (_handoff)
        {
            if (!_injector.IsRemotelyActive) return;
            id = _activeId;
            _activeId = _preparedId = null;
            _activationCancel?.Cancel();
            _injector.ReleaseAll();
            channel = Volatile.Read(ref _activeChannel);
        }
        if (channel is null) return;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        try
        {
            await channel.SendAsync(
                new MouseMessage { Type = "leave", TransferId = id, Reason = "window-close" }, timeout.Token
            ).ConfigureAwait(false);
        }
        catch (Exception error) when (
            error is IOException or OperationCanceledException or ObjectDisposedException
        )
        {
            // The paired Mac also has a local emergency-return shortcut.
            // Never block the Windows X button waiting for a broken socket.
            System.Diagnostics.Debug.WriteLine($"CrossMouse return on hide: {error.Message}");
        }
    }

    public void Start()
    {
        if (_listener is not null) return;
        _ = Native.SetProcessDPIAware();
        var listener = new TcpListener(IPAddress.Any, _port);
        // Bind synchronously so a second receiver on the same port produces
        // a clear error on the Start button rather than a background failure.
        listener.Start(backlog: 1);
        _listener = listener;
        _cancel = new CancellationTokenSource();
        StatusChanged?.Invoke(ReceiverState.Waiting, $"TCP {_port} · Mac 연결 대기 중");
        // Start is invoked by the Forms Shown/Start handler. Calling an async
        // method here directly retains WindowsFormsSynchronizationContext:
        // network reads, mouse-up injection, rendering and pong replies would
        // all depend on the same UI loop handling the native caption click.
        // Capture the session token now (Stop can clear _cancel before this
        // worker starts) and never schedule input work on the Forms thread.
        CancellationToken token = _cancel.Token;
        _loop = Task.Run(() => RunAsync(listener, token));
    }

    public async Task StopAsync()
    {
        var listener = _listener;
        if (listener is null) return;
        var task = _loop;
        var cancel = _cancel;
        _listener = null;
        _loop = null;
        _cancel = null;
        cancel?.Cancel();
        Volatile.Write(ref _activeChannel, null);
        _activeClient?.Dispose();
        listener.Stop();
        if (task is not null)
        {
            try { await task.ConfigureAwait(false); }
            catch (OperationCanceledException) { }
        }
        _injector.ReleaseAll();
        cancel?.Dispose();
        StatusChanged?.Invoke(ReceiverState.Stopped, "수신 중지됨");
    }

    private async Task RunAsync(TcpListener listener, CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                using TcpClient client = await listener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
                if (_rejectLocalPeers && IsLocalClient(client)) continue;
                _activeClient = client;
                client.NoDelay = true; // No delayed ACK/Nagle on the return path.
                try
                {
                    await using var channel = await SecureChannel.AcceptAsync(
                        client.GetStream(), _key, cancellationToken
                    ).ConfigureAwait(false);
                    Volatile.Write(ref _activeChannel, channel);
                    StatusChanged?.Invoke(ReceiverState.Connected, "Mac 연결됨 · 입력 공유 준비됨");
                    using var sessionCancel =
                        CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                    sessionCancel.CancelAfter(PeerSilenceLimit);
                    var returnPoll = CheckLeftBoundaryAsync(channel, sessionCancel.Token);
                    var render = RenderMouseAsync(sessionCancel.Token);
                    // A failed render worker must release the authenticated
                    // session, not leave an apparently live but frozen cursor.
                    _ = render.ContinueWith(_ => sessionCancel.Cancel(), CancellationToken.None,
                        TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
                        TaskScheduler.Default);
                    try
                    {
                        while (!sessionCancel.IsCancellationRequested)
                        {
                            var message = await channel.ReadAsync(sessionCancel.Token).ConfigureAwait(false);
                            // SecureChannel returns only after a complete frame
                            // has been authenticated. Raw bytes, an incomplete
                            // header/body or corrupted ciphertext never renew it.
                            sessionCancel.CancelAfter(PeerSilenceLimit);
                            // A TCP connection can look alive long after
                            // WinForms is hidden or a receiver stops
                            // processing messages. Prove the actual receiver
                            // loop is alive before Mac suppresses its cursor.
                            if (message.Type == "ping")
                            {
                                await channel.SendAsync(
                                    new MouseMessage { Type = "pong", Capability = HandoffCapability,
                                        Version = typeof(ReceiverService).Assembly.GetName().Version?.ToString(3),
                                        InputDesktop = InputDesktopAccess.CurrentName(),
                                        ServiceMode = System.Security.Principal.WindowsIdentity.GetCurrent().IsSystem },
                                    sessionCancel.Token
                                ).ConfigureAwait(false);
                                continue;
                            }
                            if (message.Type == "prepare" && message.TransferId is { Length: > 0 and <= 64 })
                            {
                                StartPreparation(message.TransferId, channel, sessionCancel.Token);
                                continue;
                            }
                            if (message.Type == "enter" && message.TransferId is not null)
                            {
                                StartAcquisition(message, channel, sessionCancel.Token);
                                continue;
                            }
                            lock (_handoff)
                            {
                                // Never replay input from a cancelled/previous ownership epoch.
                                if (_preparedId is not null && _activeId is null)
                                {
                                    if (message.Type == "leave" && message.TransferId == _preparedId)
                                    { _preparedId = null; _activationCancel?.Cancel(); }
                                    continue;
                                }
                                if (message.TransferId != _activeId)
                                {
                                    if (message.Type == "leave" && message.TransferId == _preparedId)
                                    { _preparedId = null; _activationCancel?.Cancel(); }
                                    continue;
                                }
                                if (message.Type == "leave")
                                { _activeId = _preparedId = null; _activationCancel?.Cancel(); }
                                if (message.Type == "enter") _injector.SelectTarget(null); // legacy manual entry
                                _injector.Apply(message);
                            }
                            if (message.Type == "enter")
                            {
                                // Mac must never remain parked waiting for a
                                // Windows receiver that didn't actually enter
                                // remote mouse mode.
                                await channel.SendAsync(new MouseMessage
                                {
                                    Type = _injector.IsRemotelyActive ? "entered" : "rejected"
                                }, sessionCancel.Token).ConfigureAwait(false);
                            }
                        }
                    }
                    finally
                    {
                        sessionCancel.Cancel();
                        Task? activation;
                        lock (_handoff)
                        {
                            _activeId = _preparedId = null;
                            _activationCancel?.Cancel(); activation = _activation;
                        }
                        if (activation is not null)
                        { try { await activation.ConfigureAwait(false); } catch (OperationCanceledException) { } }
                        Volatile.Write(ref _activeChannel, null);
                        try { await returnPoll.ConfigureAwait(false); }
                        catch (OperationCanceledException) { }
                        catch (IOException) { }
                        try { await render.ConfigureAwait(false); }
                        catch (OperationCanceledException) { }
                        _injector.ReleaseAll();
                    }
                }
                catch (Exception error) when (
                    error is IOException or CryptographicException or OperationCanceledException
                    or InvalidDataException or System.Text.Json.JsonException
                    or ObjectDisposedException
                )
                {
                    // Do not write key material or captured input into logs.
                    if (!cancellationToken.IsCancellationRequested)
                        StatusChanged?.Invoke(ReceiverState.Waiting, "연결 종료 · 다시 대기 중");
                }
                finally
                {
                    Volatile.Write(ref _activeChannel, null);
                    _injector.ReleaseAll();
                    _activeClient = null;
                }
                if (!cancellationToken.IsCancellationRequested)
                    StatusChanged?.Invoke(ReceiverState.Waiting, $"TCP {_port} · Mac 재연결 대기 중");
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) when (cancellationToken.IsCancellationRequested) { }
        catch (SocketException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (!cancellationToken.IsCancellationRequested)
                StatusChanged?.Invoke(ReceiverState.Faulted, $"수신 오류: {error.Message}");
        }
        finally
        {
            _injector.ReleaseAll();
            // Also clear a listener that faulted outside the ordinary
            // StopAsync path; otherwise the UI could get stuck in 'running'.
            if (_listener == listener && !cancellationToken.IsCancellationRequested)
            {
                _listener = null;
                listener.Stop();
                _cancel?.Dispose();
                _cancel = null;
                _loop = null;
            }
        }
    }

    private async Task CheckLeftBoundaryAsync(
        SecureChannel channel, CancellationToken cancellationToken
    )
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            await Task.Delay(8, cancellationToken).ConfigureAwait(false);
            string? id;
            string reason = "left-edge";
            lock (_handoff)
            {
                if (!_injector.IsRemotelyActive) continue;
                if (_injector.InputFailure is not null || InputDesktopAccess.CurrentName() is null)
                {
                    reason = "input-unavailable";
                    _injector.ReleaseAll();
                }
                else if (!_injector.ReachedLeftEdge()) continue;
                id = _activeId; _activeId = _preparedId = null;
                _activationCancel?.Cancel();
            }
            await channel.SendAsync(new MouseMessage { Type = "leave", TransferId = id,
                Reason = reason }, cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// A single render clock drives both cursor calculation and the optional
    /// visible surface. No independent Forms timer samples it at a lower rate.
    /// Waiting sleeps on a kernel event; it does not spin or run on the UI.
    /// </summary>
    private Task RenderMouseAsync(CancellationToken cancellationToken) => Task.Factory.StartNew(() =>
    {
        using var clock = new PointerFrameClock();
        WaitHandle[] handles = [cancellationToken.WaitHandle, clock];
        try
        {
            while (WaitHandle.WaitAny(handles) == 1 && !cancellationToken.IsCancellationRequested)
            {
                _injector.Tick();
                Volatile.Read(ref _presenter)?.RequestRefresh();
            }
        }
        finally
        {
            // Force one latest-state refresh on cancellation as well. Release
            // keys/buttons first so a custom pointer does not remain displayed.
            _injector.ReleaseAll();
            Volatile.Read(ref _presenter)?.RequestRefresh();
        }
    }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _activationCancel?.Dispose();
        _presenter?.Dispose();
    }

    private static bool IsLocalClient(TcpClient client)
    {
        if (client.Client.RemoteEndPoint is not IPEndPoint peer) return true;
        var address = peer.Address.IsIPv4MappedToIPv6 ? peer.Address.MapToIPv4() : peer.Address;
        if (IPAddress.IsLoopback(address)) return true;
        // A local unprivileged process must not use the previous per-user key
        // to request SYSTEM input via loopback or this machine's LAN address.
        try
        {
            return System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
                .SelectMany(n => n.GetIPProperties().UnicastAddresses).Any(a => a.Address.Equals(address));
        }
        catch (System.Net.NetworkInformation.NetworkInformationException) { return true; }
    }

    private void StartPreparation(string id, SecureChannel channel, CancellationToken session)
    {
        lock (_handoff)
        {
            if (_activeId is not null || _preparedId is not null || _injector.IsRemotelyActive) return;
            _activationCancel?.Cancel();
            _activationCancel?.Dispose();
            _activationCancel = CancellationTokenSource.CreateLinkedTokenSource(session);
            _activationCancel.CancelAfter(TimeSpan.FromSeconds(30)); // abandoned preparation lease, not a video delay
            _preparedId = id;
            _target = null;
            CancellationToken token = _activationCancel.Token;
            _activation = Task.Run(async () =>
            {
                try
                {
                    var target = TargetDisplay.Resolve();
                    lock (_handoff)
                    {
                        if (_preparedId != id || token.IsCancellationRequested) return;
                        // Resolve can outlive cancellation. Recheck ownership
                        // BEFORE any OS side effect, not just before replying.
                        if (!Native.WakePointerAt(target.Bounds.Left + target.Bounds.Width / 2,
                            target.Bounds.Top + target.Bounds.Height / 2)) throw new IOException("pointer-wake-failed");
                        _target = target;
                    }
                    await channel.SendAsync(new MouseMessage { Type = "prepared", TransferId = id,
                        Capability = HandoffCapability, Reason = target.Name }, token).ConfigureAwait(false);
                    // Expire an abandoned prepare without acquiring input.
                    // The check includes the exact owner ID so this old lease
                    // cannot cancel a later transfer in the same connection.
                    _ = Task.Run(async () =>
                    {
                        try { await Task.Delay(Timeout.InfiniteTimeSpan, token).ConfigureAwait(false); }
                        catch (OperationCanceledException)
                        {
                            lock (_handoff)
                            {
                                if (_preparedId == id && _activeId is null) _preparedId = null;
                            }
                        }
                    });
                }
                catch (Exception error) { await RejectAsync(id, channel, error, session).ConfigureAwait(false); }
            });
        }
    }

    private void StartAcquisition(MouseMessage request, SecureChannel channel, CancellationToken session)
    {
        lock (_handoff)
        {
            if (_preparedId != request.TransferId || _target is null || _activeId is not null) return;
            var preparedTarget = _target;
            string id = request.TransferId!;
            _activationCancel!.CancelAfter(TimeSpan.FromSeconds(7));
            var token = _activationCancel!.Token;
            _activation = Task.Run(async () =>
            {
                try
                {
                    // HDMI switching may recreate the monitor handle or move
                    // its bounds. Preparation's geometry is not a readiness
                    // fact; resolve the actual target again after the command.
                    var target = TargetDisplay.Resolve();
                    if (preparedTarget.Name.Contains("271E1", StringComparison.OrdinalIgnoreCase) &&
                        !target.Name.Contains("271E1", StringComparison.OrdinalIgnoreCase))
                        throw new IOException("prepared-target-no-longer-available");
                    uint? source;
                    // Observe the monitor's actual input when it supports VCP reads.
                    // Unsupported is reported, not silently treated as verified HDMI.
                    while ((source = target.InputSource()) is uint input && input != 17)
                        await Task.Delay(100, token).ConfigureAwait(false);
                    lock (_handoff)
                    {
                        if (_preparedId != id || token.IsCancellationRequested) return;
                        _injector.SelectTarget(target.Bounds);
                        _injector.Apply(request);
                        if (!_injector.IsRemotelyActive) throw new IOException("pointer-injection-rejected");
                        _activeId = id;
                        _presenter ??= new PointerPresenter(() => _injector.IsActiveForPresentation);
                    }
                    if (!await _presenter.VerifyAsync(token).ConfigureAwait(false))
                        throw new IOException("pointer-not-presented");
                    if (!Native.GetCursorPos(out var pointer) || pointer.X < target.Bounds.Left ||
                        pointer.X >= target.Bounds.Right || pointer.Y < target.Bounds.Top || pointer.Y >= target.Bounds.Bottom)
                        throw new IOException("pointer-outside-target-display");
                    lock (_handoff)
                    {
                        if (_activeId != id || token.IsCancellationRequested) return;
                        _preparedId = null;
                        _activationCancel.CancelAfter(Timeout.InfiniteTimeSpan);
                    }
                    await channel.SendAsync(new MouseMessage { Type = "entered", TransferId = id,
                        PointerVisible = true, Reason = source.HasValue ? "hdmi-observed" : "input-read-unavailable" },
                        token).ConfigureAwait(false);
                }
                catch (Exception error) { await RejectAsync(id, channel, error, session).ConfigureAwait(false); }
            });
        }
    }

    private async Task RejectAsync(string id, SecureChannel channel, Exception error, CancellationToken session)
    {
        lock (_handoff)
        {
            if (_preparedId != id && _activeId != id) return;
            _preparedId = _activeId = null;
            _activationCancel?.Cancel();
            _injector.ReleaseAll();
        }
        if (session.IsCancellationRequested) return;
        try
        {
            await channel.SendAsync(new MouseMessage { Type = "rejected", TransferId = id,
                Reason = error is OperationCanceledException ? "preparation-timeout" : error.Message }, session).ConfigureAwait(false);
        }
        catch (Exception sendError) when (sendError is IOException or OperationCanceledException or ObjectDisposedException) { }
    }
}

internal sealed class HighResolutionTimer : IDisposable
{
    [DllImport("winmm.dll", EntryPoint = "timeBeginPeriod", ExactSpelling = true)]
    private static extern uint TimeBeginPeriod(uint period);

    [DllImport("winmm.dll", EntryPoint = "timeEndPeriod", ExactSpelling = true)]
    private static extern uint TimeEndPeriod(uint period);

    private readonly bool _active;

    private HighResolutionTimer(bool active) { _active = active; }

    internal static HighResolutionTimer TryBegin()
    {
        return new HighResolutionTimer(TimeBeginPeriod(1) == 0);
    }

    public void Dispose()
    {
        if (_active) _ = TimeEndPeriod(1);
    }
}

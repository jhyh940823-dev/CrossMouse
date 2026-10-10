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
    private readonly InputInjector _injector = new(smoothMotion: true);
    private TcpListener? _listener;
    private TcpClient? _activeClient;
    private SecureChannel? _activeChannel;
    private CancellationTokenSource? _cancel;
    private Task? _loop;

    public event Action<ReceiverState, string>? StatusChanged;

    public ReceiverService(byte[] key, int port = 49431)
    {
        if (key.Length != 32) throw new ArgumentException("Invalid pairing key.", nameof(key));
        _key = key;
        _port = port;
    }

    public bool IsRunning => _listener is not null;
    public bool IsRemotelyActive => _injector.IsRemotelyActive;
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
        if (!_injector.IsRemotelyActive) return;
        _injector.ReleaseAll();
        var channel = Volatile.Read(ref _activeChannel);
        if (channel is null) return;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        try
        {
            await channel.SendAsync(
                new MouseMessage { Type = "leave" }, timeout.Token
            );
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
        _loop = RunAsync(listener, _cancel.Token);
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
            try { await task; }
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
                using TcpClient client = await listener.AcceptTcpClientAsync(cancellationToken);
                _activeClient = client;
                client.NoDelay = true; // No delayed ACK/Nagle on the return path.
                try
                {
                    await using var channel = await SecureChannel.AcceptAsync(
                        client.GetStream(), _key, cancellationToken
                    );
                    Volatile.Write(ref _activeChannel, channel);
                    StatusChanged?.Invoke(ReceiverState.Connected, "Mac 연결됨 · 입력 공유 준비됨");
                    using var sessionCancel =
                        CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                    var returnPoll = CheckLeftBoundaryAsync(channel, sessionCancel.Token);
                    var render = RenderMouseAsync(sessionCancel.Token);
                    try
                    {
                        while (!sessionCancel.IsCancellationRequested)
                        {
                            var message = await channel.ReadAsync(sessionCancel.Token);
                            _injector.Apply(message);
                        }
                    }
                    finally
                    {
                        sessionCancel.Cancel();
                        Volatile.Write(ref _activeChannel, null);
                        try { await returnPoll; }
                        catch (OperationCanceledException) { }
                        catch (IOException) { }
                        try { await render; }
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
            await Task.Delay(8, cancellationToken);
            if (_injector.ReachedLeftEdge())
                await channel.SendAsync(new MouseMessage { Type = "leave" }, cancellationToken);
        }
    }

    /// <summary>
    /// Renders the cursor at ~125Hz instead of teleporting it whenever a TCP
    /// message happens to arrive. High-resolution timer mode is requested only
    /// while Windows actually has the input focus.
    /// </summary>
    private async Task RenderMouseAsync(CancellationToken cancellationToken)
    {
        HighResolutionTimer? resolution = null;
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(8));
        try
        {
            while (await timer.WaitForNextTickAsync(cancellationToken))
            {
                if (_injector.IsRemotelyActive)
                    resolution ??= HighResolutionTimer.TryBegin();
                else
                {
                    resolution?.Dispose();
                    resolution = null;
                }
                _injector.Tick();
            }
        }
        finally
        {
            resolution?.Dispose();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
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

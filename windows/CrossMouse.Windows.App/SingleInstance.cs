using System.Security.Principal;

namespace CrossMouse.Windows.App;

/// <summary>One receiver per user/session; a manual second launch reopens the tray UI.</summary>
internal sealed class SingleInstance : IDisposable
{
    private readonly Mutex _mutex;
    private readonly string _eventName;
    private EventWaitHandle? _showEvent;
    private RegisteredWaitHandle? _wait;
    internal bool IsOwner { get; }

    internal SingleInstance(string? testSuffix = null)
    {
        string sid = WindowsIdentity.GetCurrent().User?.Value
            ?? throw new InvalidOperationException("Windows 사용자 계정을 확인할 수 없습니다.");
        string name = @"Local\CrossMouse." + sid;
        if (testSuffix is not null) name += ".Test." + testSuffix;
        _eventName = name + ".Show";
        _mutex = new Mutex(initiallyOwned: false, name);
        try { IsOwner = _mutex.WaitOne(0); }
        catch (AbandonedMutexException) { IsOwner = true; }
        if (IsOwner)
            _showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, _eventName);
    }

    internal void NotifyExisting()
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                using var show = EventWaitHandle.OpenExisting(_eventName);
                show.Set();
                return;
            }
            catch (WaitHandleCannotBeOpenedException) { Thread.Sleep(50); }
        }
    }

    internal void Listen(CrossMouseWindow window)
    {
        if (_showEvent is null) return;
        _wait = ThreadPool.RegisterWaitForSingleObject(_showEvent, (_, _) =>
        {
            try
            {
                if (!window.IsDisposed && window.IsHandleCreated)
                    window.BeginInvoke(new Action(window.ShowControls));
            }
            catch (InvalidOperationException) { /* Exiting while a second launch occurs. */ }
        }, null, Timeout.Infinite, executeOnlyOnce: false);
    }

    public void Dispose()
    {
        _wait?.Unregister(null);
        _showEvent?.Dispose();
        if (IsOwner) _mutex.ReleaseMutex();
        _mutex.Dispose();
    }
}

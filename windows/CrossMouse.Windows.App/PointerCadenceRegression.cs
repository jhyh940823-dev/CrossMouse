using System.Collections.Concurrent;
using System.Diagnostics;

namespace CrossMouse.Windows.App;

/// <summary>
/// Explicit Windows CI diagnostic. Compares the OLD 8ms Forms timer with the
/// new production clock + actual pointer surface. Uses no pairing keys, network,
/// display-input commands or clicks. Timing numbers are observations, not a
/// guarantee of a physical monitor's frame rate.
/// </summary>
internal static class PointerCadenceRegression
{
    internal static int Run()
    {
        using var watchdog = new System.Threading.Timer(_ => Environment.Exit(1), null,
            TimeSpan.FromSeconds(25), Timeout.InfiniteTimeSpan);
        try
        {
            var legacy = LegacyFormsTimer().GetAwaiter().GetResult();
            Console.WriteLine(Describe("legacy Forms.Timer Interval=8", legacy));
            CheckCurrent().GetAwaiter().GetResult();
            Console.WriteLine("PASS pointer frame cadence, bounded dispatch, cancellation and release");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"FAIL pointer cadence: {error}");
            return 1;
        }
    }

    private static Task<long[]> LegacyFormsTimer()
    {
        var done = new TaskCompletionSource<long[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                using var resolution = HighResolutionTimer.TryBegin(); // old receiver requested this
                using var window = new Form();
                _ = window.Handle;
                var times = new List<long>();
                using var timer = new System.Windows.Forms.Timer { Interval = 8 };
                var duration = Stopwatch.StartNew();
                timer.Tick += (_, _) =>
                {
                    times.Add(Stopwatch.GetTimestamp());
                    if (duration.Elapsed < TimeSpan.FromSeconds(2)) return;
                    timer.Stop();
                    done.TrySetResult(times.ToArray());
                    Application.ExitThread();
                };
                timer.Start();
                Application.Run(new ApplicationContext());
            }
            catch (Exception error) { done.TrySetException(error); }
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return done.Task;
    }

    private static async Task CheckCurrent()
    {
        int active = 1, blockNextFrame = 0;
        using var entered = new ManualResetEventSlim(false);
        using var unblock = new ManualResetEventSlim(false);
        var times = new ConcurrentQueue<long>();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        using var presenter = new PointerPresenter(() => Volatile.Read(ref active) == 1,
            observedFrameForTest: () =>
            {
                times.Enqueue(Stopwatch.GetTimestamp());
                if (Interlocked.Exchange(ref blockNextFrame, 0) == 1)
                {
                    entered.Set();
                    if (!unblock.Wait(TimeSpan.FromSeconds(3)))
                        throw new TimeoutException("Test presentation thread was not released.");
                }
            });
        Require(await presenter.VerifyAsync(timeout.Token), "Initial pointer presentation failed.");
        while (times.TryDequeue(out _)) { }
        bool highResolution = false;
        await Task.Factory.StartNew(() =>
        {
            using var clock = new PointerFrameClock();
            highResolution = clock.IsHighResolution;
            WaitHandle[] waits = [timeout.Token.WaitHandle, clock];
            var duration = Stopwatch.StartNew();
            while (duration.Elapsed < TimeSpan.FromSeconds(2) && WaitHandle.WaitAny(waits) == 1)
                presenter.RequestRefresh();
        }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        // A UI barrier makes the last frame observable without assuming that
        // posting its callback means it has already painted.
        Require(await presenter.VerifyAsync(timeout.Token), "Pointer stopped presenting.");
        var current = times.ToArray();
        Require(current.Length > 10, "Production presentation did not progress.");
        Console.WriteLine(Describe($"shared frame clock highResolution={highResolution}", current));

        Volatile.Write(ref blockNextFrame, 1);
        Task<bool> blocked = presenter.VerifyAsync(timeout.Token);
        Require(entered.Wait(TimeSpan.FromSeconds(2)), "Could not exercise busy presentation.");
        int accepted = 0;
        var dispatchTime = Stopwatch.StartNew();
        try
        {
            for (int i = 0; i < 1000; i++) if (presenter.RequestRefresh()) accepted++;
            Require(accepted <= 1, "Queued a backlog of old pointer frames.");
            Require(dispatchTime.Elapsed < TimeSpan.FromSeconds(1), "Render dispatch waited for UI painting.");
        }
        finally { unblock.Set(); }
        await blocked;
        Console.WriteLine($"PASS busy presentation: {accepted} queued callback for 1000 requests; input thread never waited");

        Volatile.Write(ref active, 0);
        Require(!await presenter.VerifyAsync(timeout.Token), "Pointer remained after input release.");
        using var cancelled = new CancellationTokenSource();
        using var clockForCancel = new PointerFrameClock();
        cancelled.Cancel();
        Require(WaitHandle.WaitAny([cancelled.Token.WaitHandle, clockForCancel]) == 0,
            "Cancellation did not take priority over another frame.");
    }

    private static string Describe(string label, long[] times)
    {
        var gaps = times.Zip(times.Skip(1), (a, b) => Stopwatch.GetElapsedTime(a, b).TotalMilliseconds)
            .OrderBy(x => x).ToArray();
        Require(gaps.Length > 0, label + " produced no samples.");
        return $"MEASURE {label}: samples={times.Length}, mean={gaps.Average():F2}ms, " +
            $"p95={gaps[(int)((gaps.Length - 1) * .95)]:F2}ms, max={gaps[^1]:F2}ms";
    }
    private static void Require(bool ok, string message) { if (!ok) throw new Exception(message); }
}

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

/// Plain CF_UNICODETEXT only, on Default. The boot broker never touches the
/// clipboard. A bounded STA operation in its interactive agent owns the HWND.
/// No arbitrary formats, file paths, clipboard reads, typing or command execution.
internal static class TextClipboardWriter
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    internal static bool IsDefaultDesktop => string.Equals(InputDesktopAccess.CurrentName(), "Default", StringComparison.OrdinalIgnoreCase);
    internal static uint Sequence => GetClipboardSequenceNumber();

    internal static async Task<string> WriteAsync(string text, uint expectedSequence,
        Func<bool> stillAuthorized, CancellationToken token)
    {
        if (!IsDefaultDesktop || !stillAuthorized()) return "unavailable";
        if (!await Gate.WaitAsync(0, token).ConfigureAwait(false)) return "busy";
        using var bound = CancellationTokenSource.CreateLinkedTokenSource(token);
        bound.CancelAfter(TimeSpan.FromMilliseconds(600));
        var operationToken = bound.Token;
        var result = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try { result.TrySetResult(Write(text, expectedSequence, stillAuthorized, operationToken)); }
            catch (Exception error) when (error is System.ComponentModel.Win32Exception or ExternalException or InvalidOperationException)
            { result.TrySetResult("unavailable"); }
            finally { Gate.Release(); }
        }) { IsBackground = true, Name = "CrossMouse.ClipboardWrite" };
        thread.SetApartmentState(ApartmentState.STA);
        try { thread.Start(); }
        catch { Gate.Release(); throw; }
        try { return await result.Task.WaitAsync(operationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) { return "cancelled"; }
    }

    private static string Write(string text, uint expectedSequence, Func<bool> authorized, CancellationToken token)
    {
        if (!IsDefaultDesktop || token.IsCancellationRequested || !authorized()) return "cancelled";
        using var desktop = InputDesktopAccess.Enter(createsWindow: true);
        if (!string.Equals(desktop.Name, "Default", StringComparison.OrdinalIgnoreCase)) return "unavailable";
        var owner = new NativeWindow();
        owner.CreateHandle(new CreateParams { Parent = new nint(-3) }); // message-only, never shown
        nint unicode = 0, history = 0;
        bool opened = false;
        try
        {
            // Normalize only line endings for Win32's Unicode text contract.
            string normalized = text.Replace("\r\n", "\n").Replace('\r', '\n').Replace("\n", "\r\n");
            unicode = Allocate(Encoding.Unicode.GetBytes(normalized + '\0'));
            history = Allocate(new byte[4]);
            uint excluded = RegisterClipboardFormatW("ExcludeClipboardContentFromMonitorProcessing");
            if (unicode == 0 || history == 0 || excluded == 0) return "unavailable";
            var wait = Stopwatch.StartNew();
            while (!(opened = OpenClipboard(owner.Handle)))
            {
                if (wait.ElapsedMilliseconds >= 250) return "busy";
                if (token.IsCancellationRequested || !authorized() || !IsDefaultDesktop) return "cancelled";
                Thread.Sleep(10);
            }
            // Do not overwrite a new local Windows copy made during transfer.
            if (GetClipboardSequenceNumber() != expectedSequence) return "local-changed";
            if (token.IsCancellationRequested || !authorized() || !IsDefaultDesktop) return "cancelled";
            if (!EmptyClipboard()) return "unavailable";
            // Opt out of Windows history/cloud before publishing the actual text.
            if (SetClipboardData(excluded, history) == 0) return "unavailable";
            history = 0;
            if (SetClipboardData(13, unicode) == 0) return "unavailable"; // CF_UNICODETEXT
            unicode = 0; // ownership belongs to Windows after success
            return "ok";
        }
        finally
        {
            if (opened) CloseClipboard();
            if (unicode != 0) GlobalFree(unicode);
            if (history != 0) GlobalFree(history);
            owner.DestroyHandle();
        }
    }
    private static nint Allocate(byte[] bytes)
    {
        nint memory = GlobalAlloc(0x42, (nuint)bytes.Length); // MOVEABLE | ZEROINIT
        if (memory == 0) return 0;
        nint pointer = GlobalLock(memory);
        if (pointer == 0) { GlobalFree(memory); return 0; }
        try { Marshal.Copy(bytes, 0, pointer, bytes.Length); }
        finally { GlobalUnlock(memory); Array.Clear(bytes); }
        return memory;
    }
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] private static extern bool OpenClipboard(nint owner);
    [DllImport("user32.dll")] private static extern bool CloseClipboard();
    [DllImport("user32.dll")] private static extern bool EmptyClipboard();
    [DllImport("user32.dll")] private static extern nint SetClipboardData(uint format, nint memory);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterClipboardFormatW(string name);
    [DllImport("kernel32.dll")] private static extern nint GlobalAlloc(uint flags, nuint size);
    [DllImport("kernel32.dll")] private static extern nint GlobalLock(nint memory);
    [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(nint memory);
    [DllImport("kernel32.dll")] private static extern nint GlobalFree(nint memory);
}

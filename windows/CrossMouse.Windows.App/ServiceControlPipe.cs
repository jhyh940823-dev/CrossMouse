using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CrossMouse.Windows.App;

/// <summary>
/// One local-only, owner-ACL control: release remote input. No arbitrary command,
/// input event, file path, key read, service installation or privilege action.
/// Network peers must still authenticate through SecureChannel.
/// </summary>
internal static class ServiceControlPipe
{
    private static string PipeName => $"CrossMouse.Return.{Process.GetCurrentProcess().SessionId}";
    internal static async Task ServeAsync(string ownerSid, ReceiverService receiver, CancellationToken token)
    {
        if (!WindowsIdentity.GetCurrent().IsSystem) throw new UnauthorizedAccessException();
        _ = new SecurityIdentifier(ownerSid);
        while (!token.IsCancellationRequested)
        {
            using var pipe = Create(ownerSid);
            await pipe.WaitForConnectionAsync(token).ConfigureAwait(false);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
            timeout.CancelAfter(TimeSpan.FromSeconds(1));
            try
            {
                string command = await ReadBoundedAsync(pipe, timeout.Token).ConfigureAwait(false);
                if (command == "return-input")
                {
                    await receiver.ReturnCursorToMacAsync().ConfigureAwait(false);
                    await pipe.WriteAsync("ok\n"u8.ToArray(), timeout.Token).ConfigureAwait(false);
                }
            }
            catch (Exception error) when (error is IOException or OperationCanceledException) { }
        }
    }
    internal static async Task<bool> ReturnInputAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        try
        {
            using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
            await pipe.ConnectAsync(timeout.Token).ConfigureAwait(false);
            if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out uint pid)) return false;
            nint process = OpenProcess(0x1000, false, pid); // QUERY_LIMITED_INFORMATION only
            if (process == 0) return false;
            try
            {
                var path = new StringBuilder(32768); uint size = (uint)path.Capacity;
                if (!QueryFullProcessImageNameW(process, 0, path, ref size) ||
                    !string.Equals(path.ToString(), SystemService.Executable, StringComparison.OrdinalIgnoreCase)) return false;
            }
            finally { CloseHandle(process); }
            await pipe.WriteAsync("return-input\n"u8.ToArray(), timeout.Token).ConfigureAwait(false);
            return await ReadBoundedAsync(pipe, timeout.Token).ConfigureAwait(false) == "ok";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or OperationCanceledException) { return false; }
    }
    private static async Task<string> ReadBoundedAsync(Stream pipe, CancellationToken token)
    {
        var data = new byte[64]; int count = 0;
        while (count < data.Length)
        {
            int read = await pipe.ReadAsync(data.AsMemory(count, 1), token).ConfigureAwait(false);
            if (read == 0) break;
            if (data[count++] == 10) return Encoding.ASCII.GetString(data, 0, count - 1);
        }
        throw new IOException("Invalid bounded local control request.");
    }
    private static NamedPipeServerStream Create(string sid)
    {
        string sddl = $"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;{sid})";
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, out nint descriptor, out _))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            var security = new SecurityAttributes { Size = Marshal.SizeOf<SecurityAttributes>(), Descriptor = descriptor };
            // Reject remote clients + first pipe instance; fail closed on a pre-existing impostor.
            var handle = CreateNamedPipeW($"\\\\.\\pipe\\{PipeName}", 3 | 0x40000000 | 0x00080000,
                0x00000008, 1, 256, 256, 0, ref security);
            if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); }
            return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle);
        }
        finally { LocalFree(descriptor); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes
    { public int Size; public nint Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool
        ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl, uint revision, out nint descriptor, out uint size);
    [DllImport("kernel32.dll")] private static extern nint LocalFree(nint value);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafePipeHandle
        CreateNamedPipeW(string name, uint openMode, uint pipeMode, uint instances, uint outBuffer, uint inBuffer,
            uint timeout, ref SecurityAttributes security);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern nint OpenProcess(uint access,
        [MarshalAs(UnmanagedType.Bool)] bool inherit, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool
        QueryFullProcessImageNameW(nint process, uint flags, StringBuilder name, ref uint size);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(nint handle);
}

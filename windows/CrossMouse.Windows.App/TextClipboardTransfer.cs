using System.Security.Cryptography;
using System.Text;
using CrossMouse.Windows;

namespace CrossMouse.Windows.App;

/// One bounded assembly per authenticated connection. Invalid, incomplete,
/// duplicate or out-of-order transfers never touch the Windows clipboard.
internal sealed class TextClipboardTransfer : IDisposable
{
    internal const string Capability = "text-chunks-1";
    internal const int MaxBytes = 256 * 1024, ChunkBytes = 2048;
    private byte[]? _bytes;
    private int _count, _index;
    private string? _id, _transfer;
    private long _started;
    internal uint SequenceAtBegin { get; private set; }
    internal bool Begin(MouseMessage message, uint sequence)
    {
        Dispose();
        if (!Guid.TryParse(message.ClipboardId, out _) || string.IsNullOrEmpty(message.TransferId) ||
            message.TransferId.Length > 64 || message.ClipboardBytes is not (>= 1 and <= MaxBytes)) return false;
        _bytes = new byte[message.ClipboardBytes.Value];
        _id = message.ClipboardId; _transfer = message.TransferId;
        _started = Environment.TickCount64; SequenceAtBegin = sequence;
        return true;
    }
    private bool Matches(MouseMessage message) => _bytes is not null && message.ClipboardId == _id &&
        message.TransferId == _transfer && Environment.TickCount64 - _started < 4000;

    internal bool Append(MouseMessage message)
    {
        if (!Matches(message) || message.ClipboardIndex != _index || message.ClipboardData is null ||
            message.ClipboardData.Length > 2732) { Dispose(); return false; }
        Span<byte> chunk = stackalloc byte[ChunkBytes];
        if (!Convert.TryFromBase64String(message.ClipboardData.Replace('-', '+').Replace('_', '/'), chunk, out int length) ||
            length != Math.Min(ChunkBytes, _bytes!.Length - _count) || length == 0)
        { Dispose(); return false; }
        chunk[..length].CopyTo(_bytes.AsSpan(_count));
        CryptographicOperations.ZeroMemory(chunk);
        _count += length; _index++;
        return true;
    }
    internal string? Finish(MouseMessage message)
    {
        try
        {
            if (!Matches(message) || _count != _bytes!.Length) return null;
            var text = new UTF8Encoding(false, true).GetString(_bytes);
            return text.Contains('\0') ? null : text;
        }
        catch (DecoderFallbackException) { return null; }
        finally { Dispose(); }
    }
    public void Dispose()
    {
        if (_bytes is not null) CryptographicOperations.ZeroMemory(_bytes);
        _bytes = null; _id = _transfer = null; _count = _index = 0;
    }
}

using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CrossMouse.Windows;

internal sealed class MouseMessage
{
    public string Type { get; set; } = "";
    public int? Dx { get; set; }
    public int? Dy { get; set; }
    public int? Button { get; set; }
    public bool? Down { get; set; }
    public int? Code { get; set; }
    public int? Vertical { get; set; }
    public int? Horizontal { get; set; }
    public double? FractionY { get; set; }
    // Automatic HDMI handoff has no meaningful left-edge entry position.
    // Place the cursor visibly inside the screen instead of the hot corner.
    public bool? CenterCursor { get; set; }
    public string? TransferId { get; set; }
    public string? Reason { get; set; }
    public string? Capability { get; set; }
    public string? Version { get; set; }
    public bool? PointerVisible { get; set; }
}

internal static class WireProtocol
{
    public const int HelloLength = 52;
    public const int MaxFrameLength = 4096;
    private static readonly byte[] Magic = "CMS1"u8.ToArray();
    private static readonly byte[] ClientLabel = "crossmouse-v1-client"u8.ToArray();
    private static readonly byte[] ServerLabel = "crossmouse-v1-server"u8.ToArray();
    private static readonly byte[] SessionLabel = "crossmouse-v1-session"u8.ToArray();
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public static byte[] ClientHello(byte[] secret, byte[] clientNonce)
    {
        Validate(secret, clientNonce);
        return Concat(Magic, clientNonce, Hmac(secret, ClientLabel, clientNonce));
    }

    public static bool VerifyClientHello(byte[] hello, byte[] secret, out byte[] clientNonce)
    {
        clientNonce = [];
        if (hello.Length != HelloLength || !hello.AsSpan(0, 4).SequenceEqual(Magic) ||
            secret.Length != 32)
        {
            return false;
        }
        clientNonce = hello.AsSpan(4, 16).ToArray();
        var expected = Hmac(secret, ClientLabel, clientNonce);
        return CryptographicOperations.FixedTimeEquals(hello.AsSpan(20, 32), expected);
    }

    public static byte[] ServerHello(byte[] secret, byte[] clientNonce, byte[] serverNonce)
    {
        Validate(secret, clientNonce);
        if (serverNonce.Length != 16) throw new ArgumentException("Server nonce must be 16 bytes.");
        return Concat(
            Magic, serverNonce, Hmac(secret, ServerLabel, clientNonce, serverNonce)
        );
    }

    public static bool VerifyServerHello(
        byte[] hello, byte[] secret, byte[] clientNonce, out byte[] serverNonce
    )
    {
        serverNonce = [];
        if (hello.Length != HelloLength || !hello.AsSpan(0, 4).SequenceEqual(Magic) ||
            secret.Length != 32 || clientNonce.Length != 16)
        {
            return false;
        }
        serverNonce = hello.AsSpan(4, 16).ToArray();
        var expected = Hmac(secret, ServerLabel, clientNonce, serverNonce);
        return CryptographicOperations.FixedTimeEquals(hello.AsSpan(20, 32), expected);
    }

    public static byte[] SessionKey(byte[] secret, byte[] clientNonce, byte[] serverNonce)
    {
        Validate(secret, clientNonce);
        if (serverNonce.Length != 16) throw new ArgumentException("Server nonce must be 16 bytes.");
        return Hmac(secret, SessionLabel, clientNonce, serverNonce);
    }

    public static byte[] Encrypt(MouseMessage message, byte[] key, ulong sequence, bool fromMac)
    {
        byte[] plaintext = JsonSerializer.SerializeToUtf8Bytes(message, Options);
        if (plaintext.Length + 16 > MaxFrameLength) throw new InvalidDataException("Frame too long.");
        byte[] nonce = MakeNonce(sequence, fromMac);
        byte[] ciphertext = new byte[plaintext.Length];
        byte[] tag = new byte[16];
        using (var aes = new AesGcm(key, 16))
        {
            aes.Encrypt(nonce, plaintext, ciphertext, tag);
        }
        byte[] frame = new byte[4 + ciphertext.Length + tag.Length];
        BinaryPrimitives.WriteInt32BigEndian(frame.AsSpan(0, 4), ciphertext.Length + tag.Length);
        ciphertext.CopyTo(frame.AsSpan(4));
        tag.CopyTo(frame.AsSpan(4 + ciphertext.Length));
        return frame;
    }

    /// <summary>Accepts ciphertext + tag, without the four-byte length prefix.</summary>
    public static MouseMessage Decrypt(ReadOnlySpan<byte> contents, byte[] key, ulong sequence, bool fromMac)
    {
        if (contents.Length < 16 || contents.Length > MaxFrameLength)
            throw new InvalidDataException("Frame length invalid.");
        byte[] plaintext = new byte[contents.Length - 16];
        using (var aes = new AesGcm(key, 16))
        {
            aes.Decrypt(
                MakeNonce(sequence, fromMac),
                contents[..^16],
                contents[^16..],
                plaintext
            );
        }
        var message = JsonSerializer.Deserialize<MouseMessage>(plaintext, Options);
        return message ?? throw new InvalidDataException("Message is missing.");
    }

    private static byte[] MakeNonce(ulong sequence, bool fromMac)
    {
        byte[] nonce = new byte[12];
        (fromMac ? "MAC1"u8 : "WIN1"u8).CopyTo(nonce);
        BinaryPrimitives.WriteUInt64BigEndian(nonce.AsSpan(4), sequence);
        return nonce;
    }

    private static byte[] Hmac(byte[] key, params byte[][] pieces)
    {
        return HMACSHA256.HashData(key, Concat(pieces));
    }

    private static void Validate(byte[] secret, byte[] clientNonce)
    {
        if (secret.Length != 32 || clientNonce.Length != 16)
            throw new ArgumentException("Invalid pairing key or handshake nonce.");
    }

    private static byte[] Concat(params byte[][] pieces)
    {
        int length = pieces.Sum(piece => piece.Length);
        var result = new byte[length];
        int offset = 0;
        foreach (var piece in pieces)
        {
            piece.CopyTo(result, offset);
            offset += piece.Length;
        }
        return result;
    }
}

internal sealed class SecureChannel : IAsyncDisposable
{
    private readonly Stream _stream;
    private readonly byte[] _sessionKey;
    private readonly SemaphoreSlim _writer = new(1, 1);
    private ulong _sendSequence;
    private ulong _receiveSequence;

    private SecureChannel(Stream stream, byte[] sessionKey)
    {
        _stream = stream;
        _sessionKey = sessionKey;
    }

    public static async Task<SecureChannel> AcceptAsync(
        Stream stream, byte[] secret, CancellationToken cancellationToken
    )
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        byte[] hello = new byte[WireProtocol.HelloLength];
        await stream.ReadExactlyAsync(hello, timeout.Token).ConfigureAwait(false);
        if (!WireProtocol.VerifyClientHello(hello, secret, out var clientNonce))
            throw new CryptographicException("Client authentication failed.");

        byte[] serverNonce = RandomNumberGenerator.GetBytes(16);
        byte[] response = WireProtocol.ServerHello(secret, clientNonce, serverNonce);
        await stream.WriteAsync(response, timeout.Token).ConfigureAwait(false);
        byte[] sessionKey = WireProtocol.SessionKey(secret, clientNonce, serverNonce);
        return new SecureChannel(stream, sessionKey);
    }

    public async Task<MouseMessage> ReadAsync(CancellationToken cancellationToken)
    {
        byte[] header = new byte[4];
        await _stream.ReadExactlyAsync(header, cancellationToken).ConfigureAwait(false);
        int length = BinaryPrimitives.ReadInt32BigEndian(header);
        if (length < 16 || length > WireProtocol.MaxFrameLength)
            throw new InvalidDataException("Rejected oversized/invalid encrypted packet.");
        byte[] payload = new byte[length];
        await _stream.ReadExactlyAsync(payload, cancellationToken).ConfigureAwait(false);
        return WireProtocol.Decrypt(payload, _sessionKey, _receiveSequence++, fromMac: true);
    }

    public async Task SendAsync(MouseMessage message, CancellationToken cancellationToken)
    {
        await _writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            byte[] frame = WireProtocol.Encrypt(
                message, _sessionKey, _sendSequence++, fromMac: false
            );
            await _stream.WriteAsync(frame, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _writer.Release();
        }
    }

    public ValueTask DisposeAsync()
    {
        _writer.Dispose();
        return ValueTask.CompletedTask;
    }
}

import Foundation

/// Parses a TCP byte stream without relying on `Data` slice indices.
///
/// `Data.removeFirst` can leave `startIndex` nonzero. Numeric ranges such as
/// `buffer[4..<length]` then trap despite `buffer.count` being sufficient.
/// A zero-indexed byte array avoids that failure after a handshake is consumed.
public struct FramedByteBuffer: Sendable {
    private var bytes: [UInt8] = []
    public static let maxBufferedBytes = 32_768

    public init() {}

    public var count: Int { bytes.count }

    public mutating func append(_ data: Data) throws {
        guard data.count <= Self.maxBufferedBytes - bytes.count else {
            throw CrossMouseError.invalidFrame
        }
        bytes.append(contentsOf: data)
    }

    /// Reads exactly `length` bytes, or leaves the buffer untouched if incomplete.
    public mutating func take(_ length: Int) -> Data? {
        guard length >= 0, bytes.count >= length else { return nil }
        let result = Data(bytes.prefix(length))
        bytes.removeFirst(length)
        return result
    }

    /// Reads a 4-byte big-endian length prefix and its encrypted payload.
    /// Returns the payload without the prefix, or nil for a partial frame.
    public mutating func takeEncryptedFrame() throws -> Data? {
        guard bytes.count >= 4 else { return nil }
        let length = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length >= 16, length <= CrossMouseWire.maxFrameLength else {
            throw CrossMouseError.invalidFrame
        }
        let total = Int(length) + 4
        guard bytes.count >= total else { return nil }
        let result = Data(bytes[4..<total])
        bytes.removeFirst(total)
        return result
    }
}

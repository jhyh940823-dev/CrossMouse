import CryptoKit
import Foundation

public enum CrossMouseError: Error, LocalizedError {
    case invalidSecret
    case invalidHandshake
    case invalidFrame
    case unauthenticated

    public var errorDescription: String? {
        switch self {
        case .invalidSecret: return "Pairing key must be 64 hexadecimal characters (32 bytes)."
        case .invalidHandshake: return "CrossMouse handshake is invalid."
        case .invalidFrame: return "CrossMouse encrypted frame is invalid."
        case .unauthenticated: return "CrossMouse pairing key does not match."
        }
    }
}

public struct CrossMouseMessage: Codable, Equatable, Sendable {
    public let type: String
    public var dx: Int?
    public var dy: Int?
    public var button: Int?
    public var down: Bool?
    public var code: Int?
    public var vertical: Int?
    public var horizontal: Int?
    public var fractionY: Double?
    public var centerCursor: Bool?
    public var transferId: String?
    public var reason: String?
    public var capability: String?
    public var version: String?
    public var pointerVisible: Bool?
    public var motionTimeUs: Int64?

    public init(
        type: String,
        dx: Int? = nil,
        dy: Int? = nil,
        button: Int? = nil,
        down: Bool? = nil,
        code: Int? = nil,
        vertical: Int? = nil,
        horizontal: Int? = nil,
        fractionY: Double? = nil,
        centerCursor: Bool? = nil,
        transferId: String? = nil,
        reason: String? = nil,
        capability: String? = nil,
        version: String? = nil,
        pointerVisible: Bool? = nil,
        motionTimeUs: Int64? = nil
    ) {
        self.type = type
        self.dx = dx
        self.dy = dy
        self.button = button
        self.down = down
        self.code = code
        self.vertical = vertical
        self.horizontal = horizontal
        self.fractionY = fractionY
        self.centerCursor = centerCursor
        self.transferId = transferId
        self.reason = reason
        self.capability = capability
        self.version = version
        self.pointerVisible = pointerVisible
        self.motionTimeUs = motionTimeUs
    }
}

public enum WireDirection: Sendable {
    case macToWindows
    case windowsToMac

    public var noncePrefix: Data {
        Data((self == .macToWindows ? "MAC1" : "WIN1").utf8)
    }
}

/// A small, versioned, authenticated encrypted wire format.
///
/// Both endpoints must have the same randomly generated 32-byte pairing secret.
/// A fresh client and server nonce derives a new session key for every TCP connection.
/// Frames use AES-256-GCM, deterministic direction-separated 96-bit nonces and ordered
/// counters. Never reuse a session key with a reset counter.
public enum CrossMouseWire {
    public static let magic = Data("CMS1".utf8)
    public static let helloLength = 52
    public static let maxFrameLength = 4_096
    private static let sessionLabel = Data("crossmouse-v1-session".utf8)
    private static let clientLabel = Data("crossmouse-v1-client".utf8)
    private static let serverLabel = Data("crossmouse-v1-server".utf8)

    public static func decodeKey(_ hex: String) throws -> Data {
        let characters = Array(hex.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard characters.count == 64 else { throw CrossMouseError.invalidSecret }
        var output = Data()
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard
                let hi = hexNibble(characters[index]),
                let lo = hexNibble(characters[index + 1])
            else {
                throw CrossMouseError.invalidSecret
            }
            output.append(hi << 4 | lo)
        }
        return output
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 65 + 10
        case 97...102: return byte - 97 + 10
        default: return nil
        }
    }

    public static func clientHello(secret: Data, clientNonce: Data) throws -> Data {
        guard secret.count == 32, clientNonce.count == 16 else { throw CrossMouseError.invalidHandshake }
        let authentication = hmac(secret: secret, data: clientLabel + clientNonce)
        return magic + clientNonce + authentication
    }

    public static func serverHello(secret: Data, clientNonce: Data, serverNonce: Data) throws -> Data {
        guard secret.count == 32, clientNonce.count == 16, serverNonce.count == 16 else {
            throw CrossMouseError.invalidHandshake
        }
        let authentication = hmac(secret: secret, data: serverLabel + clientNonce + serverNonce)
        return magic + serverNonce + authentication
    }

    public static func verifyServerHello(
        _ response: Data, secret: Data, clientNonce: Data
    ) throws -> Data {
        guard response.count == helloLength, response.prefix(4) == magic,
              clientNonce.count == 16 else { throw CrossMouseError.invalidHandshake }
        let serverNonce = Data(response[4..<20])
        let expectedData = serverLabel + clientNonce + serverNonce
        guard HMAC<SHA256>.isValidAuthenticationCode(
            Data(response[20..<52]), authenticating: expectedData,
            using: SymmetricKey(data: secret)
        ) else {
            throw CrossMouseError.unauthenticated
        }
        return serverNonce
    }

    public static func sessionKey(
        secret: Data, clientNonce: Data, serverNonce: Data
    ) throws -> Data {
        guard secret.count == 32, clientNonce.count == 16, serverNonce.count == 16 else {
            throw CrossMouseError.invalidHandshake
        }
        return hmac(secret: secret, data: sessionLabel + clientNonce + serverNonce)
    }

    public static func frame(
        _ message: CrossMouseMessage,
        sessionKey: Data,
        sequence: UInt64,
        direction: WireDirection
    ) throws -> Data {
        let plaintext = try JSONEncoder().encode(message)
        let nonce = try AES.GCM.Nonce(data: nonceData(direction: direction, sequence: sequence))
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: sessionKey), nonce: nonce)
        let encrypted = sealed.ciphertext + sealed.tag
        guard encrypted.count <= maxFrameLength else { throw CrossMouseError.invalidFrame }
        var length = UInt32(encrypted.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(encrypted)
        return frame
    }

    /// Takes only frame contents, without the 4-byte length prefix.
    public static func open(
        _ encrypted: Data,
        sessionKey: Data,
        sequence: UInt64,
        direction: WireDirection
    ) throws -> CrossMouseMessage {
        guard encrypted.count >= 16, encrypted.count <= maxFrameLength else {
            throw CrossMouseError.invalidFrame
        }
        let split = encrypted.count - 16
        let nonce = try AES.GCM.Nonce(data: nonceData(direction: direction, sequence: sequence))
        let sealed = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: Data(encrypted[..<split]),
            tag: Data(encrypted[split...])
        )
        let plaintext = try AES.GCM.open(sealed, using: SymmetricKey(data: sessionKey))
        return try JSONDecoder().decode(CrossMouseMessage.self, from: plaintext)
    }

    private static func nonceData(direction: WireDirection, sequence: UInt64) -> Data {
        var value = sequence.bigEndian
        return direction.noncePrefix + withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func hmac(secret: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: secret)))
    }
}

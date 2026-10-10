import Foundation
import XCTest
@testable import CrossMouseCore

final class WireProtocolTests: XCTestCase {
    private let secret = Data((0..<32).map(UInt8.init))
    private let clientNonce = Data((0..<16).map(UInt8.init))
    private let serverNonce = Data((16..<32).map(UInt8.init))

    func testHandshakeAndEncryptedMessageRoundTrip() throws {
        let client = try CrossMouseWire.clientHello(secret: secret, clientNonce: clientNonce)
        XCTAssertEqual(client.count, 52)
        XCTAssertEqual(Data(client.prefix(4)), CrossMouseWire.magic)
        let server = try CrossMouseWire.serverHello(
            secret: secret, clientNonce: clientNonce, serverNonce: serverNonce
        )
        XCTAssertEqual(
            try CrossMouseWire.verifyServerHello(server, secret: secret, clientNonce: clientNonce),
            serverNonce
        )
        let key = try CrossMouseWire.sessionKey(
            secret: secret, clientNonce: clientNonce, serverNonce: serverNonce
        )
        let message = CrossMouseMessage(type: "move", dx: 13, dy: -7)
        let frame = try CrossMouseWire.frame(
            message, sessionKey: key, sequence: 0, direction: .macToWindows
        )
        XCTAssertEqual(
            try CrossMouseWire.open(
                Data(frame.dropFirst(4)), sessionKey: key,
                sequence: 0, direction: .macToWindows
            ),
            message
        )
    }

    func testInvalidSecretAndTamperingAreRejected() throws {
        XCTAssertThrowsError(try CrossMouseWire.decodeKey("abc"))
        let key = try CrossMouseWire.sessionKey(
            secret: secret, clientNonce: clientNonce, serverNonce: serverNonce
        )
        let frame = try CrossMouseWire.frame(
            CrossMouseMessage(type: "key", code: 55, down: true),
            sessionKey: key, sequence: 5, direction: .macToWindows
        )
        XCTAssertThrowsError(
            try CrossMouseWire.open(
                Data(frame.dropFirst(4)), sessionKey: key,
                sequence: 6, direction: .macToWindows
            )
        )
        XCTAssertThrowsError(
            try CrossMouseWire.open(
                Data(frame.dropFirst(4)), sessionKey: key,
                sequence: 5, direction: .windowsToMac
            )
        )
        var corrupted = Data(frame.dropFirst(4))
        corrupted[0] ^= 0x01
        XCTAssertThrowsError(
            try CrossMouseWire.open(
                corrupted, sessionKey: key, sequence: 5, direction: .macToWindows
            )
        )
        let invalidHello = try CrossMouseWire.serverHello(
            secret: secret, clientNonce: clientNonce, serverNonce: serverNonce
        )
        XCTAssertThrowsError(
            try CrossMouseWire.verifyServerHello(
                invalidHello, secret: Data(repeating: 9, count: 32), clientNonce: clientNonce
            )
        )
    }

    func testKeyHexParsing() throws {
        let expected = secret.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try CrossMouseWire.decodeKey(expected.uppercased()), secret)
        XCTAssertThrowsError(try CrossMouseWire.decodeKey(String(repeating: "g", count: 64)))
    }

    func testCrossLanguageGoldenVectors() throws {
        let clientHello = try CrossMouseWire.clientHello(
            secret: secret, clientNonce: clientNonce
        )
        XCTAssertEqual(
            Data(clientHello.suffix(32)).map { String(format: "%02x", $0) }.joined(),
            "3682ada3f76c1cc5f061a4f57cb12967e11876f06627af8befede33f9bfdec3a"
        )
        let key = try CrossMouseWire.sessionKey(
            secret: secret, clientNonce: clientNonce, serverNonce: serverNonce
        )
        XCTAssertEqual(
            key.map { String(format: "%02x", $0) }.joined(),
            "7fe924fb2373ff3980cb7b713cbbf28e52553a739895eade120f7492a26e792d"
        )
        // This frame is created from the .NET JSON shape (ordered as below)
        // with AES-GCM/MAC1 sequence 7, calculated independently.
        let fixtureHex = "00000034b24ca63a9487c156df44e1d997b1c4af6874f3d6e2af3cefb4832c539d610bca6c73641ef6f86fc9bd340a43e05c25d0f8fb6d34"
        let chars = Array(fixtureHex)
        let frame = Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
        let message = try CrossMouseWire.open(
            Data(frame.dropFirst(4)), sessionKey: key,
            sequence: 7, direction: .macToWindows
        )
        XCTAssertEqual(message, CrossMouseMessage(type: "key", down: true, code: 55))
    }
}

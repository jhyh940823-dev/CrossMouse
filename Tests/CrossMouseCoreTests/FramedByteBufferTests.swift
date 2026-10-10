import Foundation
import XCTest
@testable import CrossMouseCore

final class FramedByteBufferTests: XCTestCase {
    func testCoalescedHandshakeAndFrames() throws {
        let key = Data(repeating: 0xA5, count: 32)
        let hello = Data(repeating: 0x42, count: CrossMouseWire.helloLength)
        let frame0 = try CrossMouseWire.frame(
            CrossMouseMessage(type: "leave"),
            sessionKey: key, sequence: 0, direction: .windowsToMac
        )
        let frame1 = try CrossMouseWire.frame(
            CrossMouseMessage(type: "leave"),
            sessionKey: key, sequence: 1, direction: .windowsToMac
        )
        var buffer = FramedByteBuffer()
        try buffer.append(hello + frame0 + frame1)
        XCTAssertEqual(buffer.take(CrossMouseWire.helloLength), hello)
        XCTAssertEqual(buffer.count, frame0.count + frame1.count)
        XCTAssertEqual(
            try CrossMouseWire.open(
                try XCTUnwrap(buffer.takeEncryptedFrame()), sessionKey: key,
                sequence: 0, direction: .windowsToMac
            ).type,
            "leave"
        )
        XCTAssertEqual(
            try CrossMouseWire.open(
                try XCTUnwrap(buffer.takeEncryptedFrame()), sessionKey: key,
                sequence: 1, direction: .windowsToMac
            ).type,
            "leave"
        )
        XCTAssertEqual(buffer.count, 0)
        XCTAssertNil(try buffer.takeEncryptedFrame())
    }

    func testEveryByteBoundaryAfterHandshake() throws {
        let key = Data(repeating: 0x12, count: 32)
        let hello = Data(repeating: 0xEE, count: CrossMouseWire.helloLength)
        let frame = try CrossMouseWire.frame(
            CrossMouseMessage(type: "leave"),
            sessionKey: key, sequence: 0, direction: .windowsToMac
        )
        for split in 0...frame.count {
            var buffer = FramedByteBuffer()
            try buffer.append(hello + frame.prefix(split))
            XCTAssertEqual(buffer.take(CrossMouseWire.helloLength), hello)
            if split < frame.count {
                XCTAssertNil(try buffer.takeEncryptedFrame())
            }
            try buffer.append(Data(frame.dropFirst(split)))
            let message = try CrossMouseWire.open(
                try XCTUnwrap(buffer.takeEncryptedFrame()), sessionKey: key,
                sequence: 0, direction: .windowsToMac
            )
            XCTAssertEqual(message.type, "leave")
        }
    }

    func testMalformedLengthAndExcessBytesRejected() throws {
        var invalid = FramedByteBuffer()
        try invalid.append(Data([0, 0, 16, 1]))
        XCTAssertThrowsError(try invalid.takeEncryptedFrame())
        var huge = FramedByteBuffer()
        try huge.append(Data(repeating: 0, count: FramedByteBuffer.maxBufferedBytes))
        XCTAssertThrowsError(try huge.append(Data([1])))
    }
}

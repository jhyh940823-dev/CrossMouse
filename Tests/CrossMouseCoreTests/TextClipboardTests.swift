import AppKit
import XCTest
@testable import CrossMouseCore

final class TextClipboardTests: XCTestCase {
    func testUnicodeChunksRemainWithinOriginalEncryptedFrameLimit() throws {
        let text = String(repeating: "한글🙂\nlet value = \"a\\b\";\t\u{ffff}", count: 2000)
        let id = UUID().uuidString
        let frames = try XCTUnwrap(TextClipboardWire.frames(text, transferId: id, clipboardId: id))
        XCTAssertEqual(frames.first?.clipboardBytes, text.utf8.count)
        XCTAssertEqual(frames.last?.type, "clipboard-commit")
        var decoded = Data()
        for (sequence, frame) in frames.enumerated() {
            let wire = try CrossMouseWire.frame(frame, sessionKey: Data(repeating: 7, count: 32),
                sequence: UInt64(sequence), direction: .macToWindows)
            XCTAssertLessThanOrEqual(wire.count - 4, 4096)
            XCTAssertEqual(try CrossMouseWire.open(Data(wire.dropFirst(4)), sessionKey: Data(repeating: 7, count: 32),
                sequence: UInt64(sequence), direction: .macToWindows), frame)
            if let chunk = frame.clipboardData {
                XCTAssertEqual(frame.clipboardIndex, sequence - 1)
                decoded.append(try XCTUnwrap(Data(base64Encoded: chunk.replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/"))))
            }
        }
        XCTAssertEqual(String(data: decoded, encoding: .utf8), text)
    }

    func testBoundsAndEmbeddedNullAreRejectedWithoutTruncation() {
        let id = UUID().uuidString
        for text in ["", "a\0b", String(repeating: "a", count: TextClipboardWire.maxBytes + 1)] {
            XCTAssertNil(TextClipboardWire.frames(text, transferId: id, clipboardId: id))
        }
        XCTAssertNotNil(TextClipboardWire.frames(String(repeating: "a", count: TextClipboardWire.maxBytes),
                                                transferId: id, clipboardId: id))
        XCTAssertNil(TextClipboardWire.frames("a", transferId: "", clipboardId: id))
        XCTAssertNil(TextClipboardWire.frames("a", transferId: id, clipboardId: "invalid"))
    }

    @MainActor
    func testNamedPasteboardAckOnlyAndLocalCopyPreservation() throws {
        let board = NSPasteboard(name: .init("CrossMouse-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let reader = MacTextClipboard()
        board.clearContents(); board.setString("한글\n코드🙂", forType: .string)
        guard case .text(let snapshot) = reader.read(board) else { return XCTFail("Missing fixture") }
        XCTAssertEqual(snapshot.text, "한글\n코드🙂")
        // Sending but not acknowledging must remain retryable on another entry.
        guard case .text = reader.read(board) else { return XCTFail("Unacknowledged copy was lost") }
        reader.acknowledge(changeCount: snapshot.changeCount)
        guard case .unchanged = reader.read(board) else { return XCTFail("Unchanged Mac text would overwrite Windows copy") }
        board.clearContents(); board.setString("한글\n코드🙂", forType: .string)
        guard case .text = reader.read(board) else { return XCTFail("New copy of same text was ignored") }
    }

    @MainActor
    func testProtectedAndFilePasteboardsDoNotExposeText() {
        let board = NSPasteboard(name: .init("CrossMouse-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let reader = MacTextClipboard()
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "public.file-url"] {
            board.declareTypes([.string, .init(marker)], owner: nil)
            board.setString("synthetic-private-fixture", forType: .string)
            board.setData(Data(), forType: .init(marker))
            guard case .excluded = reader.read(board) else { return XCTFail("Protected fixture was shared") }
        }
        board.clearContents(); board.setData(Data([1, 2, 3]), forType: .png)
        guard case .unavailable = reader.read(board) else { return XCTFail("Image treated as text") }
    }
}

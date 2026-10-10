import XCTest
@testable import CrossMouseCore

final class MonitorHandoffGateTests: XCTestCase {
    func testAutomaticCenterFlagIsOptionalAndEncrypted() throws {
        let old = try JSONDecoder().decode(CrossMouseMessage.self,
            from: Data(#"{"type":"enter","fractionY":0.5}"#.utf8))
        XCTAssertNil(old.centerCursor)
        let message = CrossMouseMessage(type: "enter", fractionY: 0.5, centerCursor: true)
        let key = Data(repeating: 7, count: 32)
        let frame = try CrossMouseWire.frame(message, sessionKey: key, sequence: 1, direction: .macToWindows)
        let decoded = try CrossMouseWire.open(Data(frame.dropFirst(4)), sessionKey: key,
            sequence: 1, direction: .macToWindows)
        XCTAssertEqual(decoded, message)
    }
    func testDDCCompletionDoesNotImmediatelyCaptureInput() {
        var gate = MonitorHandoffGate()
        let token = gate.begin()
        XCTAssertEqual(gate.poll(at: 100), .waiting)
        XCTAssertTrue(gate.commandCompleted(token, at: 100))
        XCTAssertEqual(gate.poll(at: 100.01), .waiting)
        XCTAssertEqual(gate.poll(at: 101.49), .waiting)
        XCTAssertEqual(gate.poll(at: 101.5), .ready)
        XCTAssertFalse(gate.isPending)
        XCTAssertEqual(gate.poll(at: 104), .waiting)
    }

    func testDisplayNotificationExtendsQuietIntervalButDoesNotReturnToMac() {
        var gate = MonitorHandoffGate()
        let token = gate.begin()
        gate.commandCompleted(token, at: 10)
        gate.displayChanged(at: 11.4)
        XCTAssertEqual(gate.poll(at: 11.5), .waiting)
        XCTAssertEqual(gate.poll(at: 11.81), .ready)
    }

    func testCancellationAndStaleDDCCompletionCannotReenterWindows() {
        var gate = MonitorHandoffGate()
        let cancelled = gate.begin()
        gate.cancel()
        XCTAssertFalse(gate.commandCompleted(cancelled, at: 10))
        let newer = gate.begin()
        XCTAssertFalse(gate.commandCompleted(cancelled, at: 11))
        XCTAssertTrue(gate.commandCompleted(newer, at: 12))
        gate.cancel()
        XCTAssertEqual(gate.poll(at: 20), .waiting)
    }

    func testUnstableDisplaysHaveBoundedWait() {
        var gate = MonitorHandoffGate()
        let token = gate.begin()
        gate.commandCompleted(token, at: 0)
        gate.displayChanged(at: 4.9)
        XCTAssertEqual(gate.poll(at: 5.1), .timedOut)
        XCTAssertFalse(gate.isPending)
    }

    func testOnlyRealAnchorChangesReclaimCursor() {
        let samsung = CursorAnchorGeometry(displayID: 1,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        // Philips input change notification with unchanged Samsung geometry.
        XCTAssertFalse(samsung.requiresReclaim(after: samsung, online: true))
        XCTAssertTrue(samsung.requiresReclaim(after: samsung, online: false))
        XCTAssertTrue(samsung.requiresReclaim(after: .init(displayID: 2,
            bounds: samsung.bounds), online: true))
        XCTAssertTrue(samsung.requiresReclaim(after: .init(displayID: 1,
            bounds: CGRect(x: 0, y: 0, width: 1280, height: 720)), online: true))
    }
}

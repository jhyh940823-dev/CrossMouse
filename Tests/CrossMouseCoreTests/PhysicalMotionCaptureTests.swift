import XCTest
@testable import CrossMouseCore

final class PhysicalMotionCaptureTests: XCTestCase {
    func testPreTransferAndQueuedReportsCannotMoveNewOwner() {
        var capture = PhysicalMotionCapture()
        XCTAssertFalse(capture.accepts(reportTimestamp: 99))
        capture.begin(at: 100)
        XCTAssertFalse(capture.accepts(reportTimestamp: 99))
        XCTAssertFalse(capture.accepts(reportTimestamp: 100))
        XCTAssertTrue(capture.accepts(reportTimestamp: 101))
        capture.end()
        XCTAssertFalse(capture.accepts(reportTimestamp: 102))
        capture.begin(at: 200)
        XCTAssertFalse(capture.accepts(reportTimestamp: 150))
        XCTAssertTrue(capture.accepts(reportTimestamp: 201))
    }
}

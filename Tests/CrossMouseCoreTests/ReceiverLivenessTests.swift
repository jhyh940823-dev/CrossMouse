import XCTest
@testable import CrossMouseCore

final class ReceiverLivenessTests: XCTestCase {
    func testSocketConnectionAloneDoesNotPermitInputCapture() {
        var receiver = ReceiverLiveness(maxSilence: 2.5)
        XCTAssertFalse(receiver.isResponsive(at: 10))
        receiver.confirm(at: 10)
        XCTAssertTrue(receiver.isResponsive(at: 12))
        XCTAssertTrue(receiver.isResponsive(at: 12.5))
        XCTAssertFalse(receiver.isResponsive(at: 12.51))
    }

    func testPongsRefreshAndReconnectionClearsPermission() {
        var receiver = ReceiverLiveness()
        receiver.confirm(at: 30)
        XCTAssertTrue(receiver.isResponsive(at: 32))
        receiver.confirm(at: 32)
        XCTAssertTrue(receiver.isResponsive(at: 33))
        receiver.reset()
        XCTAssertFalse(receiver.isResponsive(at: 33))
        receiver.confirm(at: 40)
        XCTAssertTrue(receiver.isResponsive(at: 40.1))
    }

    func testClockRegressionNeverAllowsInputCapture() {
        var receiver = ReceiverLiveness()
        receiver.confirm(at: 100)
        XCTAssertFalse(receiver.isResponsive(at: 99))
    }
}

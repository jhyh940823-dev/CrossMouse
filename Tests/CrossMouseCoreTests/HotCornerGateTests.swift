import XCTest
@testable import CrossMouseCore

final class HotCornerGateTests: XCTestCase {
    func testMustDwellWithoutLeaving() {
        var gate = HotCornerGate(dwellSeconds: 1.25)
        XCTAssertEqual(gate.update(inside: true, now: 10, enabled: true), .holding(0))
        XCTAssertEqual(gate.update(inside: true, now: 10.5, enabled: true), .holding(0.4))
        XCTAssertEqual(gate.update(inside: false, now: 10.8, enabled: true), .idle)
        XCTAssertEqual(gate.update(inside: true, now: 11, enabled: true), .holding(0))
        XCTAssertEqual(gate.update(inside: true, now: 12, enabled: true), .holding(0.8))
        XCTAssertEqual(gate.update(inside: true, now: 12.25, enabled: true), .triggered)
    }

    func testOnlyOneTriggerBeforeLeavingCorner() {
        var gate = HotCornerGate(dwellSeconds: 1.0)
        XCTAssertEqual(gate.update(inside: true, now: 0, enabled: true), .holding(0))
        XCTAssertEqual(gate.update(inside: true, now: 1.1, enabled: true), .triggered)
        XCTAssertEqual(gate.update(inside: true, now: 2, enabled: true), .idle)
        XCTAssertEqual(gate.update(inside: false, now: 2.1, enabled: true), .idle)
        XCTAssertEqual(gate.update(inside: true, now: 3, enabled: true), .holding(0))
    }

    func testDisabledGateNeverTriggersOrRetainsProgress() {
        var gate = HotCornerGate(dwellSeconds: 1.0)
        XCTAssertEqual(gate.update(inside: true, now: 0, enabled: true), .holding(0))
        XCTAssertEqual(gate.update(inside: true, now: 5, enabled: false), .idle)
        XCTAssertEqual(gate.update(inside: true, now: 6, enabled: true), .holding(0))
    }
}

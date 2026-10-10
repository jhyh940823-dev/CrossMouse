import XCTest
@testable import CrossMouseCore

final class AutomaticHandoffTests: XCTestCase {
    func testCommandsAndWrongOrderDoNotAcquireInput() {
        var state = AutomaticHandoff()
        state.begin(id: "one", now: 0)
        XCTAssertFalse(state.ownsInput)
        XCTAssertFalse(state.acquired("one", visible: true, now: 1))
        XCTAssertTrue(state.prepared("one", now: 1))
        XCTAssertFalse(state.ownsInput)
        XCTAssertTrue(state.switched("one", now: 2))
        XCTAssertFalse(state.acquired("one", visible: false, now: 3))
        XCTAssertFalse(state.ownsInput)
        XCTAssertTrue(state.acquired("one", visible: true, now: 3))
        XCTAssertTrue(state.ownsInput)
        XCTAssertFalse(state.expired(at: 600)) // idle is not a return request
    }
    func testLateOrUnidentifiedLeaveCannotSwitchMonitorBack() {
        var state = AutomaticHandoff()
        state.begin(id: "old", now: 0); state.cancel()
        state.begin(id: "new", now: 1)
        XCTAssertFalse(state.prepared("old", now: 1))
        XCTAssertTrue(state.prepared("new", now: 1))
        XCTAssertTrue(state.switched("new", now: 2))
        XCTAssertTrue(state.acquired("new", visible: true, now: 3))
        XCTAssertFalse(state.returning(nil, reason: "left-edge", now: 4))
        XCTAssertFalse(state.returning("old", reason: "left-edge", now: 4))
        XCTAssertFalse(state.returning("new", reason: "idle", now: 4))
        XCTAssertTrue(state.ownsInput)
        XCTAssertTrue(state.returning("new", reason: "left-edge", now: 5))
        XCTAssertFalse(state.returned("old"))
        XCTAssertTrue(state.returned("new"))
        XCTAssertEqual(state.phase, .local)
    }
    func testCancelledDDCCompletionCannotAcquireOrFinishNewTransaction() {
        var state = AutomaticHandoff()
        state.begin(id:"a", now:0); _ = state.prepared("a", now:1)
        state.cancel(); state.begin(id:"b", now:2)
        XCTAssertFalse(state.switched("a", now:3))
        XCTAssertEqual(state.phase, .preparing("b"))
        XCTAssertTrue(state.expired(at: 11))
    }
}

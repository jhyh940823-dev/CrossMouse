import XCTest
@testable import CrossMouseCore

final class CoexistenceTests: XCTestCase {
    private func enteredWindows() -> AutomaticHandoff {
        var state = AutomaticHandoff()
        state.begin(id: "initial", now: 0)
        XCTAssertTrue(state.prepared("initial", now: 1))
        XCTAssertEqual(state.phase, .switchingToWindows("initial"))
        XCTAssertTrue(state.switched("initial", now: 2))
        XCTAssertTrue(state.acquired("initial", visible: true, now: 3))
        return state
    }

    func testRepeatedCrossingsKeepHDMIAndDoNotRequestAnyDDCWrite() {
        var state = enteredWindows()
        var current = "initial"
        for i in 1...20 {
            XCTAssertTrue(state.releaseInput(current, reason: "left-edge", now: Double(i * 4)))
            XCTAssertEqual(state.phase, .local)
            XCTAssertEqual(state.displayInput, .windowsHDMI)
            XCTAssertFalse(state.expired(at: 10000))
            XCTAssertTrue(state.canEnterFromSamsung)
            let next = "crossing-\(i)"
            XCTAssertNotNil(state.begin(id: next, switchDisplay: false,
                                        fractionY: 0.7, now: Double(i * 4 + 1)))
            XCTAssertFalse(state.canEnterFromSamsung) // one handshake at a time
            XCTAssertTrue(state.prepared(next, now: Double(i * 4 + 2)))
            XCTAssertEqual(state.phase, .acquiring(next)) // no switchingToWindows
            XCTAssertFalse(state.switchesDisplayOnEntry)
            XCTAssertEqual(state.entryFractionY, 0.7)
            XCTAssertFalse(state.switched(next, now: Double(i * 4 + 2)))
            XCTAssertFalse(state.releaseInput(current, reason: "left-edge", now: 99))
            XCTAssertTrue(state.acquired(next, visible: true, now: Double(i * 4 + 3)))
            XCTAssertFalse(state.returned(current))
            current = next
        }
    }

    func testWindowXReturnsOnlyInputAndKeepsWindowsPicture() {
        var state = enteredWindows()
        XCTAssertTrue(state.releaseInput("initial", reason: "window-close", now: 4))
        XCTAssertEqual(state.displayInput, .windowsHDMI)
        XCTAssertTrue(state.canEnterFromSamsung)
    }

    func testOnlyExplicitDVIReturnChangesPanelAndReenablesOriginalHotCorner() {
        var state = enteredWindows()
        XCTAssertNil(state.requestMacDisplay(id: "invalid", now: 4)) // release owner first
        XCTAssertEqual(state.cancel(), "initial")
        XCTAssertEqual(state.displayInput, .windowsHDMI)
        XCTAssertEqual(state.requestMacDisplay(id: "dvi", now: 5), "dvi")
        XCTAssertFalse(state.canEnterFromSamsung)
        XCTAssertFalse(state.returned("initial"))
        XCTAssertTrue(state.returned("dvi"))
        XCTAssertEqual(state.displayInput, .macDVI)
        XCTAssertNil(state.begin(id: "ordinary-edge", switchDisplay: false, now: 6))
        XCTAssertNotNil(state.begin(id: "hotcorner", now: 7))
        XCTAssertTrue(state.prepared("hotcorner", now: 8))
        XCTAssertEqual(state.phase, .switchingToWindows("hotcorner"))
    }

    func testDVIReturnFromSamsungWhileWindowsPictureIsRetained() {
        var state = enteredWindows()
        _ = state.releaseInput("initial", reason: "left-edge", now: 4)
        XCTAssertNotNil(state.requestMacDisplay(id: "dvi-on-mac", now: 5))
        XCTAssertTrue(state.returned("dvi-on-mac"))
        XCTAssertEqual(state.displayInput, .macDVI)
    }

    func testCancelledReentryAndFailedDVILeavePanelSelectionUnchanged() {
        var state = enteredWindows()
        _ = state.releaseInput("initial", reason: "left-edge", now: 4)
        _ = state.begin(id: "retry", switchDisplay: false, now: 5)
        _ = state.prepared("retry", now: 6)
        _ = state.cancel()
        XCTAssertEqual(state.displayInput, .windowsHDMI)
        XCTAssertFalse(state.acquired("retry", visible: true, now: 7))
        _ = state.requestMacDisplay(id: "failed-dvi", now: 8)
        _ = state.cancel()
        XCTAssertEqual(state.displayInput, .windowsHDMI)
        XCTAssertFalse(state.returned("failed-dvi"))
        XCTAssertTrue(state.canEnterFromSamsung)
    }

    func testReentryWaitsForVisibleAcknowledgmentAndRetainsEpochIsolation() {
        var state = enteredWindows()
        _ = state.releaseInput("initial", reason: "left-edge", now: 4)
        _ = state.begin(id: "next", switchDisplay: false, now: 5)
        XCTAssertFalse(state.acquired("next", visible: true, now: 6))
        _ = state.prepared("next", now: 6)
        XCTAssertFalse(state.acquired("next", visible: false, now: 7))
        XCTAssertFalse(state.acquired("initial", visible: true, now: 7))
        XCTAssertTrue(state.acquired("next", visible: true, now: 8))
        XCTAssertFalse(state.releaseInput("initial", reason: "window-close", now: 9))
        XCTAssertTrue(state.ownsInput)
    }
}

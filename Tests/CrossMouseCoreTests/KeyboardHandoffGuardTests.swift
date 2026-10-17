import CoreGraphics
import XCTest
@testable import CrossMouseCore

final class KeyboardHandoffGuardTests: XCTestCase {
    func testAcquisitionUsesHardwareStateNotAnInterceptedSessionKey() {
        XCTAssertEqual(KeyboardHandoffGuard.acquisitionSource, .hidSystemState)
        // Synthetic session table says V is down after interception, while
        // physical hardware has released it. The acquisition adapter uses HID.
        XCTAssertTrue(KeyboardHandoffGuard.canAcquire(flags: [], buttonsDown: false, keyDown: { _ in false }))
        XCTAssertFalse(KeyboardHandoffGuard.canAcquire(flags: [], buttonsDown: false, keyDown: { $0 == 9 }))
    }
    func testMomentaryKeysOrButtonsBlockAcquisitionButCapsAndFnDoNot() {
        for flag: CGEventFlags in [.maskControl, .maskCommand, .maskAlternate, .maskShift] {
            XCTAssertFalse(KeyboardHandoffGuard.canAcquire(flags: flag, buttonsDown: false, keyDown: { _ in false }))
        }
        XCTAssertFalse(KeyboardHandoffGuard.canAcquire(flags: [], buttonsDown: true, keyDown: { _ in false }))
        XCTAssertFalse(KeyboardHandoffGuard.canAcquire(flags: [], buttonsDown: false, keyDown: { $0 == 9 }))
        XCTAssertTrue(KeyboardHandoffGuard.canAcquire(flags: [.maskAlphaShift, .maskSecondaryFn],
            buttonsDown: false, keyDown: { $0 == 57 || $0 == 63 }))
        XCTAssertTrue(KeyboardHandoffGuard.canAcquire(flags: [], buttonsDown: false, keyDown: { _ in false }))
    }
    func testQueuedSeamRequestCannotSurviveNewMacChordOrClick() {
        for event: CGEventType in [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            var intent = KeyboardHandoffGuard()
            let queued = intent.revision
            XCTAssertTrue(intent.observeLocal(event))
            XCTAssertFalse(intent.isCurrent(queued))
        }
    }
    func testMotionAndKeyReleaseAloneDoNotInvalidateIntent() {
        var intent = KeyboardHandoffGuard()
        let queued = intent.revision
        for event: CGEventType in [.mouseMoved, .keyUp, .leftMouseUp, .scrollWheel] {
            XCTAssertFalse(intent.observeLocal(event))
        }
        XCTAssertTrue(intent.isCurrent(queued))
        intent.invalidate() // F8, explicit return, disconnect or lost input tap
        XCTAssertFalse(intent.isCurrent(queued))
    }
    func testLateWindowsReadyCannotStealChordStartedDuringPreparation() {
        for afterPreparation in [false, true] {
            var handoff = AutomaticHandoff(displayInput: .windowsHDMI)
            _ = handoff.begin(id: "waiting", switchDisplay: false, now: 0)
            if afterPreparation { XCTAssertTrue(handoff.prepared("waiting", now: 1)) }
            var guardState = KeyboardHandoffGuard()
            if guardState.observeLocal(.keyDown) && KeyboardHandoffGuard.awaitsWindowsInput(handoff.phase) {
                XCTAssertEqual(handoff.cancel(), "waiting")
            }
            XCTAssertFalse(handoff.acquired("waiting", visible: true, now: 2))
            XCTAssertFalse(handoff.ownsInput)
            XCTAssertEqual(handoff.displayInput, .windowsHDMI) // no DVI side effect
        }
    }
    func testTypingDoesNotCancelExplicitDVIOrAlreadyOwnedWindows() {
        XCTAssertFalse(KeyboardHandoffGuard.awaitsWindowsInput(.local))
        XCTAssertFalse(KeyboardHandoffGuard.awaitsWindowsInput(.windows("active")))
        XCTAssertFalse(KeyboardHandoffGuard.awaitsWindowsInput(.switchingToMac("f8")))
        XCTAssertTrue(KeyboardHandoffGuard.awaitsWindowsInput(.switchingToWindows("entry")))
    }
}

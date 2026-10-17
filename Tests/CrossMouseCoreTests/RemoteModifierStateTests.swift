import CoreGraphics
import XCTest
@testable import CrossMouseCore

final class RemoteModifierStateTests: XCTestCase {
    private func key(_ code: Int, _ down: Bool) -> CrossMouseMessage {
        CrossMouseMessage(type: "key", down: down, code: code)
    }
    // NX device-side masks from the platform IOLLEvent.h, with aggregate flags.
    private let leftControl = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x1)
    private let leftCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)

    func testReleaseObservedAfterLocalPressNeverCreatesWindowsLogoDown() {
        var state = RemoteModifierState()
        state.reset()
        // Mac Control maps to Windows logo. Its DOWN happened on Mac before
        // entry; the first remotely observed event is UP, not a new DOWN.
        XCTAssertEqual(state.update(flags: []), [])
    }
    func testDuplicateFlagsChangedDoesNotInvertCommand() {
        var state = RemoteModifierState()
        XCTAssertEqual(state.update(flags: leftCommand), [key(55, true)])
        XCTAssertEqual(state.update(flags: leftCommand), [])
        XCTAssertEqual(state.update(flags: []), [key(55, false)])
    }
    func testNextOrdinaryEventRepairsMissingModifierReleaseBeforePaste() {
        var state = RemoteModifierState()
        XCTAssertEqual(state.update(flags: leftControl), [key(59, true)])
        // A later V or pointer event no longer carries Control; reconcile the
        // Windows logo UP before processing that event, even without flagsChanged.
        XCTAssertEqual(state.update(flags: []), [key(59, false)])
        XCTAssertEqual(state.update(flags: []), [])
    }
    func testMissingDownIsReconciledBeforeOrdinaryKey() {
        var state = RemoteModifierState()
        XCTAssertEqual(state.update(flags: leftCommand), [key(55, true)])
        XCTAssertEqual(state.update(flags: leftCommand), [])
        XCTAssertEqual(state.update(flags: []), [key(55, false)])
    }

    func testBothSidesRemainIndependentAndReleaseExactlyOnce() {
        for (aggregate, left, leftMask, right, rightMask) in [
            (CGEventFlags.maskCommand, 55, UInt64(0x8), 54, UInt64(0x10)),
            (.maskControl, 59, 0x1, 62, 0x2000),
            (.maskAlternate, 58, 0x20, 61, 0x40),
            (.maskShift, 56, 0x2, 60, 0x4)
        ] {
            var state = RemoteModifierState()
            let l = CGEventFlags(rawValue: aggregate.rawValue | leftMask)
            let both = CGEventFlags(rawValue: aggregate.rawValue | leftMask | rightMask)
            let r = CGEventFlags(rawValue: aggregate.rawValue | rightMask)
            XCTAssertEqual(state.update(flags: l), [key(left, true)])
            XCTAssertEqual(state.update(flags: both), [key(right, true)])
            XCTAssertEqual(state.update(flags: r), [key(left, false)])
            XCTAssertEqual(state.update(flags: []), [key(right, false)])
            XCTAssertEqual(state.update(flags: []), [])
        }
    }
    func testAggregateOnlySourceUsesExplicitSideStateNotEventParity() {
        var state = RemoteModifierState()
        XCTAssertEqual(state.update(flags: .maskControl, sideKeyState: { $0 == 62 }), [key(62, true)])
        XCTAssertEqual(state.update(flags: .maskControl, sideKeyState: { $0 == 59 }),
                       [key(62, false), key(59, true)])
        XCTAssertEqual(state.update(flags: .maskControl, sideKeyState: { _ in false }), [key(59, false)])
        // Aggregate-only synthetic source without an OS side table has a
        // deterministic logical-left representation, never an alternating key.
        XCTAssertEqual(state.update(flags: .maskCommand), [key(55, true)])
        XCTAssertEqual(state.update(flags: .maskCommand), [])
    }
    func testStaleDeviceBitsWithoutAggregateCannotCreateHeldKeys() {
        var state = RemoteModifierState()
        XCTAssertEqual(state.update(flags: CGEventFlags(rawValue: 0x207f)), [])
    }
    func testReleaseDeltasPrecedeNewChordAndEncryptedWireRemainsCompatible() throws {
        var state = RemoteModifierState()
        _ = state.update(flags: leftControl)
        let transitions = state.update(flags: leftCommand) + [key(9, true), key(9, false)]
        XCTAssertEqual(transitions, [key(59, false), key(55, true), key(9, true), key(9, false)])
        let session = Data(repeating: 23, count: 32) // test-only, not a user key
        for (index, message) in transitions.enumerated() {
            let frame = try CrossMouseWire.frame(message, sessionKey: session, sequence: UInt64(index), direction: .macToWindows)
            XCTAssertEqual(try CrossMouseWire.open(Data(frame.dropFirst(4)), sessionKey: session,
                sequence: UInt64(index), direction: .macToWindows), message)
        }
    }
    func testCapsChangesAreCompletePressesAndFnIsNotAWindowsModifier() {
        var state = RemoteModifierState()
        state.reset(flags: .maskAlphaShift)
        XCTAssertEqual(state.update(flags: [.maskAlphaShift, .maskSecondaryFn]), [])
        XCTAssertEqual(state.update(flags: []), [key(57, true), key(57, false)])
        XCTAssertEqual(state.update(flags: .maskAlphaShift), [key(57, true), key(57, false)])
        XCTAssertEqual(state.update(flags: .maskAlphaShift), [])
    }
    func testRepeatedAcquisitionsDoNotReuseOldModifierState() {
        var state = RemoteModifierState()
        for _ in 0..<500 {
            state.reset()
            XCTAssertEqual(state.update(flags: []), [])
            XCTAssertEqual(state.update(flags: leftControl), [key(59, true)])
            XCTAssertEqual(state.update(flags: leftCommand), [key(59, false), key(55, true)])
            XCTAssertEqual(state.update(flags: []), [key(55, false)])
        }
    }
    func testUnpostedCGEventsCarryReleaseSnapshotThroughDecoder() throws {
        var state = RemoteModifierState()
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: false))
        event.type = .flagsChanged
        event.flags = []
        XCTAssertEqual(state.update(flags: event.flags), [])
        event.flags = leftCommand
        XCTAssertEqual(state.update(flags: event.flags), [key(55, true)])
        event.flags = []
        XCTAssertEqual(state.update(flags: event.flags), [key(55, false)])
        // No event is posted and neither computer's OS key state is modified.
    }
}

import XCTest
@testable import CrossMouseCore

final class DisplayReturnShortcutTests: XCTestCase {
    private let f8 = DisplayReturnShortcut.keyCode

    func testSingleF8RequestsAndConsumesReleaseAfterMacReturn() {
        var shortcut = DisplayReturnShortcut()
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: true, enabled: true), .requestDVI)
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: false, enabled: false), .consume)
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: false, enabled: false), .pass)
    }

    func testHeldKeyNeverRepeatsDVIOrLeaksAfterDisplayChanged() {
        var shortcut = DisplayReturnShortcut()
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: true, enabled: true), .requestDVI)
        for _ in 0..<20 {
            XCTAssertEqual(shortcut.handle(keyCode: f8, down: true, isRepeat: true,
                                            enabled: false), .consume)
        }
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: true, enabled: true), .consume)
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: false, enabled: true), .consume)
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: true, enabled: true), .requestDVI)
    }

    func testOtherKeysAndModifiedF8AreNotTakenFromApps() {
        var shortcut = DisplayReturnShortcut()
        for code in [2, 53, 99, 101] {
            XCTAssertEqual(shortcut.handle(keyCode: code, down: true, enabled: true), .pass)
            XCTAssertEqual(shortcut.handle(keyCode: code, down: false, enabled: true), .pass)
        }
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: true, hasModifiers: true,
                                        enabled: true), .pass)
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: false, enabled: true), .pass)
    }

    func testAlreadyMacDualKeepsNormalF8Behavior() {
        var shortcut = DisplayReturnShortcut()
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: true, enabled: false), .pass)
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: true, isRepeat: true,
                                        enabled: false), .pass)
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: false, enabled: false), .pass)
    }

    func testModeChangeWhileHoldingUncapturedF8DoesNotRequestDVI() {
        var shortcut = DisplayReturnShortcut()
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: true, enabled: false), .pass)
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: true, isRepeat: true,
                                        enabled: true), .pass)
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: false, enabled: true), .pass)
    }

    func testTapResetDoesNotReuseAnOldPress() {
        var shortcut = DisplayReturnShortcut()
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: true, enabled: true), .requestDVI)
        shortcut.reset()
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: true, isRepeat: true,
                                        enabled: true), .pass)
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: false, enabled: true), .pass)
        XCTAssertEqual(shortcut.handle(keyCode: f8, down: true, enabled: true), .requestDVI)
    }
}

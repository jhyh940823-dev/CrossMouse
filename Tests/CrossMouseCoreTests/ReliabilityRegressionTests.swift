import Foundation
import XCTest
@testable import CrossMouseCore

final class ReliabilityRegressionTests: XCTestCase {
    func testCachedDVISelectionCannotDisableF8WhenActualInputIsUnreadable() {
        var state = AutomaticHandoff(displayInput: .unknown)
        state.restoreDisplaySelection(.macDVI)
        XCTAssertEqual(state.displayInput, .macDVI) // normal Mac routing retained
        XCTAssertFalse(state.hasCurrentDisplaySelection)
        XCTAssertTrue(state.needsDisplayReturnShortcut)
        var shortcut = DisplayReturnShortcut()
        XCTAssertEqual(shortcut.handle(keyCode: 100, down: true, enabled: state.needsDisplayReturnShortcut), .requestDVI)
        state.selectDisplay(.macDVI) // DVI selected during this run
        XCTAssertFalse(state.needsDisplayReturnShortcut)
        XCTAssertEqual(shortcut.handle(keyCode: 100, down: false, enabled: false), .consume)
        XCTAssertEqual(shortcut.handle(keyCode: 100, down: true, enabled: false), .pass)
    }
    func testReceiverDiagnosticsDecodeWithoutChangingLegacyPackets() throws {
        let current = Data(#"{"type":"pong","version":"0.5.0","capability":"handoff-2","serviceMode":true,"inputDesktop":"Winlogon","pointerState":"surface:Winlogon"}"#.utf8)
        let decoded = try JSONDecoder().decode(CrossMouseMessage.self, from: current)
        XCTAssertEqual(decoded.serviceMode, true)
        XCTAssertEqual(decoded.inputDesktop, "Winlogon")
        XCTAssertEqual(decoded.pointerState, "surface:Winlogon")
        XCTAssertEqual(try JSONDecoder().decode(CrossMouseMessage.self,
            from: JSONEncoder().encode(decoded)), decoded)
        let legacy = try JSONDecoder().decode(CrossMouseMessage.self, from: Data(#"{"type":"pong"}"#.utf8))
        XCTAssertNil(legacy.serviceMode)
        XCTAssertNil(legacy.inputDesktop)
        XCTAssertNil(legacy.pointerState)
    }
    func testLostF8ReleaseCannotDisableFuturePressesForever() {
        for source in [DisplayReturnShortcut.Source.functionF8, .playPause] {
            var key = DisplayReturnShortcut()
            XCTAssertEqual(key.handle(source: source, down: true, enabled: true), .requestDVI)
            // No key-up arrives across a desktop/tap change. A fresh non-repeat
            // down is a NEW press, not a request to remain permanently latched.
            XCTAssertEqual(key.handle(source: source, down: true, isRepeat: true, enabled: false), .consume)
            XCTAssertEqual(key.handle(source: source, down: true, enabled: true), .requestDVI)
            XCTAssertEqual(key.handle(source: source, down: false, enabled: false), .consume)
        }
    }
}

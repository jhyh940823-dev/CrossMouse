import AppKit
import XCTest
@testable import CrossMouseCore

final class DisplayReturnEventTests: XCTestCase {
    private func function(down: Bool = true, repeatKey: Bool = false,
                          flags: CGEventFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 100, keyDown: down))
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return event
    }

    private func media(code: Int = 16, state: Int = 0x0a, repeatKey: Bool = false,
                       subtype: Int16 = 8, flags: NSEvent.ModifierFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(NSEvent.otherEvent(with: .systemDefined, location: .zero,
            modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, subtype: subtype,
            data1: (code << 16) | (state << 8) | (repeatKey ? 1 : 0), data2: -1))
        return try XCTUnwrap(event.cgEvent)
    }

    private func decision(_ event: CGEvent, _ shortcut: inout DisplayReturnShortcut,
                          enabled: Bool = true) -> DisplayReturnShortcut.Decision {
        DisplayReturnEvent(type: event.type, event: event)?.apply(to: &shortcut, enabled: enabled) ?? .pass
    }

    func testActualEventMaskIncludesBothF8Representations() throws {
        for event in try [function(), function(down: false), media(), media(state: 0x0b)] {
            XCTAssertNotEqual(DisplayReturnEvent.eventMask & (1 << event.type.rawValue), 0)
        }
    }

    func testNormalF8ThroughProductionDecoderWithFnFlag() throws {
        var shortcut = DisplayReturnShortcut()
        XCTAssertEqual(decision(try function(flags: [.maskSecondaryFn]), &shortcut), .requestDVI)
        XCTAssertEqual(decision(try function(down: false), &shortcut, enabled: false), .consume)
    }

    func testMediaRepresentationRequestsOnceAndConsumesReleaseAfterDVI() throws {
        var shortcut = DisplayReturnShortcut()
        XCTAssertEqual(decision(try media(), &shortcut), .requestDVI)
        for _ in 0..<10 {
            XCTAssertEqual(decision(try media(repeatKey: true), &shortcut, enabled: false), .consume)
        }
        XCTAssertEqual(decision(try media(state: 0x0b), &shortcut, enabled: false), .consume)
        XCTAssertEqual(decision(try media(), &shortcut, enabled: false), .pass)
        XCTAssertEqual(decision(try media(state: 0x0b), &shortcut, enabled: false), .pass)
    }

    func testUnrelatedAndMalformedSystemEventsAreNotShortcut() throws {
        var shortcut = DisplayReturnShortcut()
        for code in [0, 1, 2, 3, 7, 14, 17, 18, 20] { // volume, brightness, next/previous, etc.
            XCTAssertEqual(decision(try media(code: code), &shortcut), .pass)
        }
        XCTAssertEqual(decision(try media(state: 0), &shortcut), .pass)
        XCTAssertEqual(decision(try media(subtype: 7), &shortcut), .pass)
    }

    func testModifiedMediaAndPressStartedInDVIKeepNativeBehavior() throws {
        var shortcut = DisplayReturnShortcut()
        for flag in [NSEvent.ModifierFlags.control, .option, .shift, .command] {
            XCTAssertEqual(decision(try media(flags: flag), &shortcut), .pass)
            XCTAssertEqual(decision(try media(state: 0x0b, flags: flag), &shortcut), .pass)
        }
        XCTAssertEqual(decision(try media(), &shortcut, enabled: false), .pass)
        XCTAssertEqual(decision(try media(repeatKey: true), &shortcut), .pass)
        XCTAssertEqual(decision(try media(state: 0x0b), &shortcut), .pass)
    }

    func testSourcesCannotReleaseEachOthersCapturedPress() throws {
        var shortcut = DisplayReturnShortcut()
        XCTAssertEqual(decision(try function(), &shortcut), .requestDVI)
        XCTAssertEqual(decision(try media(state: 0x0b), &shortcut), .pass)
        XCTAssertEqual(decision(try function(repeatKey: true), &shortcut, enabled: false), .consume)
        XCTAssertEqual(decision(try function(down: false), &shortcut, enabled: false), .consume)
        XCTAssertEqual(decision(try media(), &shortcut), .requestDVI)
        shortcut.reset()
        XCTAssertEqual(decision(try media(state: 0x0b), &shortcut), .pass)
    }
}

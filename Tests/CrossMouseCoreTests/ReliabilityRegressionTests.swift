import XCTest
@testable import CrossMouseCore

final class ReliabilityRegressionTests: XCTestCase {
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

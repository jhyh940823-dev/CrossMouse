import XCTest
@testable import CrossMouseCore

final class PointerMotionScaleTests: XCTestCase {
    func testDefaultHalvesOnlyForwardedMovement() {
        var scale = PointerMotionScale()
        let move = scale.apply(dx: 100, dy: -60)
        XCTAssertEqual(move.dx, 50); XCTAssertEqual(move.dy, -30)
    }
    func testTinyMotionAccumulatesInsteadOfSticking() {
        var scale = PointerMotionScale(percent: 25)
        var x = 0, y = 0
        for _ in 0..<400 {
            let move = scale.apply(dx: 1, dy: -1)
            x += move.dx; y += move.dy
        }
        XCTAssertEqual(x, 100); XCTAssertEqual(y, -100)
    }
    func testDirectionReversalsDoNotDrift() {
        var scale = PointerMotionScale(percent: 37)
        var x = 0, y = 0
        for _ in 0..<100 {
            for dx in [1, -1] {
                let move = scale.apply(dx: dx, dy: -dx)
                x += move.dx; y += move.dy
            }
        }
        XCTAssertEqual(x, 0); XCTAssertEqual(y, 0)
    }
    func testNonBinaryPercentageHasNoRoundingDrift() {
        var scale = PointerMotionScale(percent: 37)
        var x = 0
        for _ in 0..<10000 { x += scale.apply(dx: 1, dy: 0).dx }
        XCTAssertEqual(x, 3700)
    }
    func testAxesAreIndependentAndZeroReportCannotManufactureMotion() {
        var scale = PointerMotionScale()
        XCTAssertEqual(scale.apply(dx: 1, dy: 0).dx, 0)
        XCTAssertEqual(scale.apply(dx: 0, dy: 1).dy, 0)
        let zero = scale.apply(dx: 0, dy: 0)
        XCTAssertEqual(zero.dx, 0); XCTAssertEqual(zero.dy, 0)
        let next = scale.apply(dx: 1, dy: 1)
        XCTAssertEqual(next.dx, 1); XCTAssertEqual(next.dy, 1)
    }
    func testOwnershipAndSpeedChangesClearFractionalCarry() {
        var scale = PointerMotionScale()
        _ = scale.apply(dx: 1, dy: -1)
        scale.reset()
        XCTAssertEqual(scale.apply(dx: 1, dy: 0).dx, 0)
        scale.setPercent(25)
        XCTAssertEqual(scale.apply(dx: 1, dy: 0).dx, 0)
    }
    func testInvalidSettingsAreBoundedAndRestoreProducesSameSpeed() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(PointerMotionScale(percent: value).percent, 50)
        }
        XCTAssertEqual(PointerMotionScale(percent: -10).percent, 25)
        XCTAssertEqual(PointerMotionScale(percent: 1000).percent, 150)
        let saved = PointerMotionScale.normalized(41.2)
        var restored = PointerMotionScale(percent: saved)
        XCTAssertEqual(restored.apply(dx: 100, dy: 0).dx, 41)
    }
}

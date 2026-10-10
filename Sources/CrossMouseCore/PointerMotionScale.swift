import Foundation

/// Scales only the motion forwarded to Windows. Sub-pixel remainders preserve
/// slow one-count HID movements instead of rounding every report to zero.
/// Reset at each ownership boundary so old motion cannot leak to a new owner.
public struct PointerMotionScale: Sendable {
    public static let defaultPercent = 50.0
    public static let minimumPercent = 25.0
    public static let maximumPercent = 150.0
    public private(set) var percent: Double
    private var remainderX = 0
    private var remainderY = 0

    public init(percent: Double = Self.defaultPercent) {
        self.percent = Self.normalized(percent)
    }
    public static func normalized(_ percent: Double) -> Double {
        guard percent.isFinite else { return defaultPercent }
        return min(maximumPercent, max(minimumPercent, percent)).rounded()
    }
    public mutating func setPercent(_ value: Double) {
        let next = Self.normalized(value)
        guard next != percent else { return }
        percent = next
        reset()
    }
    public mutating func reset() { remainderX = 0; remainderY = 0 }

    public mutating func apply(dx: Int, dy: Int) -> (dx: Int, dy: Int) {
        // Integer percent arithmetic avoids floating-point drift at e.g. 37%.
        let x = min(32768, max(-32768, dx)) * Int(percent) + remainderX
        let y = min(32768, max(-32768, dy)) * Int(percent) + remainderY
        let result = (dx: x / 100, dy: y / 100)
        remainderX = x % 100
        remainderY = y % 100
        return result
    }
}

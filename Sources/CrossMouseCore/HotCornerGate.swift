import Foundation

/// Deliberate edge trigger: the pointer must remain in a small screen corner
/// for a continuous dwell interval. Moving away resets the countdown.
/// Once fired the gate cannot fire again until the pointer leaves the corner.
public struct HotCornerGate: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case holding(Double)
        case triggered
    }

    private var beganAt: TimeInterval?
    private var hasTriggered = false
    public let dwellSeconds: TimeInterval

    public init(dwellSeconds: TimeInterval = 1.25) {
        self.dwellSeconds = max(0.5, dwellSeconds)
    }

    public mutating func reset() {
        beganAt = nil
        hasTriggered = false
    }

    /// `inside` must be true only at the physically rightmost/topmost corner
    /// of the intended monitor; caller separately checks connectivity and mode.
    public mutating func update(
        inside: Bool, now: TimeInterval, enabled: Bool
    ) -> Phase {
        guard enabled, inside else {
            reset()
            return .idle
        }
        guard !hasTriggered else { return .idle }
        guard let start = beganAt else {
            beganAt = now
            return .holding(0)
        }
        let elapsed = max(0, now - start)
        guard elapsed >= dwellSeconds else {
            return .holding(min(1, elapsed / dwellSeconds))
        }
        hasTriggered = true
        return .triggered
    }
}

import Foundation

/// A connected TCP socket does not prove that the Windows input receiver is
/// still processing events. Require fresh, authenticated application-level
/// pong frames before allowing macOS to suppress the local cursor.
public struct ReceiverLiveness: Sendable {
    public let maxSilence: TimeInterval
    private var lastResponseAt: TimeInterval?

    public init(maxSilence: TimeInterval = 2.5) {
        self.maxSilence = max(1, maxSilence)
    }

    public mutating func confirm(at uptime: TimeInterval) {
        lastResponseAt = uptime
    }

    public mutating func reset() {
        lastResponseAt = nil
    }

    public func isResponsive(at uptime: TimeInterval) -> Bool {
        guard let lastResponseAt, uptime >= lastResponseAt else { return false }
        return uptime - lastResponseAt <= maxSilence
    }
}

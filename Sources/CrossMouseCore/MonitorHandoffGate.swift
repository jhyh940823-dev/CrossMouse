import Foundation
import CoreGraphics

/// A DDC command completing is not a video-ready acknowledgement. Keep input
/// on Mac for a bounded settling interval, and reject stale command callbacks
/// after the user cancels, disconnects, or selects a different mode.
public struct MonitorHandoffGate: Sendable {
    public enum Readiness: Equatable, Sendable {
        case waiting
        case ready
        case timedOut
    }

    private var generation: UInt64 = 0
    private var current: UInt64?
    private var commandCompletedAt: TimeInterval?
    private var lastDisplayChangeAt: TimeInterval = 0
    public var isPending: Bool { current != nil }
    public var isSettling: Bool { current != nil && commandCompletedAt != nil }

    public init() {}

    public mutating func begin() -> UInt64 {
        generation &+= 1
        current = generation
        commandCompletedAt = nil
        return generation
    }

    public func accepts(_ token: UInt64) -> Bool { current == token }

    @discardableResult
    public mutating func commandCompleted(_ token: UInt64, at now: TimeInterval) -> Bool {
        guard accepts(token) else { return false }
        commandCompletedAt = now
        lastDisplayChangeAt = now
        return true
    }

    public mutating func displayChanged(at now: TimeInterval) {
        if isSettling { lastDisplayChangeAt = now }
    }

    public mutating func cancel() {
        current = nil
        commandCompletedAt = nil
    }

    public mutating func poll(at now: TimeInterval) -> Readiness {
        guard let completed = commandCompletedAt, isPending else { return .waiting }
        if now - completed > 5 {
            cancel()
            return .timedOut
        }
        guard now - completed >= 1.5, now - lastDisplayChangeAt >= 0.4 else { return .waiting }
        cancel()
        return .ready
    }
}

/// A notification about Philips must not reclaim input when the Samsung
/// display used for parking the Mac cursor has not actually changed.
public struct CursorAnchorGeometry: Equatable, Sendable {
    public let displayID: UInt32
    public let bounds: CGRect
    public init(displayID: UInt32, bounds: CGRect) {
        self.displayID = displayID
        self.bounds = bounds
    }

    public func requiresReclaim(after next: Self, online: Bool) -> Bool {
        !online || next.bounds.isEmpty || self != next
    }
}

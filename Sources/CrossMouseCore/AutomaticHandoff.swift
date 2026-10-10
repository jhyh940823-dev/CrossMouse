import Foundation

/// One owner of an automatic monitor/input transaction. Sending a command
/// never implies that video changed or that Windows owns the input. Replies
/// from a cancelled/previous transaction have no authority over the next one.
public struct AutomaticHandoff: Sendable {
    public enum Phase: Equatable, Sendable {
        case local
        case preparing(String)
        case switchingToWindows(String)
        case acquiring(String)
        case windows(String)
        case switchingToMac(String)
    }
    public private(set) var phase: Phase = .local
    public private(set) var changedAt: TimeInterval = 0
    public init() {}
    public var id: String? {
        switch phase {
        case .local: nil
        case .preparing(let id), .switchingToWindows(let id), .acquiring(let id),
             .windows(let id), .switchingToMac(let id): id
        }
    }
    public var ownsInput: Bool { if case .windows = phase { true } else { false } }
    public var inProgress: Bool { phase != .local }

    @discardableResult
    public mutating func begin(id: String = UUID().uuidString, now: TimeInterval) -> String? {
        guard phase == .local else { return nil }
        phase = .preparing(id); changedAt = now; return id
    }
    public mutating func prepared(_ replyID: String?, now: TimeInterval) -> Bool {
        guard case .preparing(let id) = phase, replyID == id else { return false }
        phase = .switchingToWindows(id); changedAt = now; return true
    }
    public mutating func switched(_ replyID: String?, now: TimeInterval) -> Bool {
        guard case .switchingToWindows(let id) = phase, replyID == id else { return false }
        phase = .acquiring(id); changedAt = now; return true
    }
    public mutating func acquired(_ replyID: String?, visible: Bool, now: TimeInterval) -> Bool {
        guard case .acquiring(let id) = phase, replyID == id, visible else { return false }
        phase = .windows(id); changedAt = now; return true
    }
    public mutating func returning(_ replyID: String?, reason: String?, now: TimeInterval) -> Bool {
        guard case .windows(let id) = phase, replyID == id,
              reason == "left-edge" || reason == "window-close" else { return false }
        phase = .switchingToMac(id); changedAt = now; return true
    }
    public mutating func returned(_ replyID: String?) -> Bool {
        guard case .switchingToMac(let id) = phase, replyID == id else { return false }
        phase = .local; return true
    }
    @discardableResult
    public mutating func cancel() -> String? { let old = id; phase = .local; return old }
    public func expired(at now: TimeInterval) -> Bool {
        switch phase {
        case .local, .windows: false
        default: now - changedAt > 8 // failure deadline, never a readiness delay
        }
    }
}

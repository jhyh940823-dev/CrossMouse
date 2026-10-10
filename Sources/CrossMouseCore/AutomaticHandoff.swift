import Foundation

/// Display selection and input ownership are independent. Returning the cursor
/// to Samsung does NOT change Philips' input. Only an explicit display-return
/// request may enter switchingToMac. Each acquisition still has a fresh ID.
public struct AutomaticHandoff: Sendable {
    public enum DisplayInput: Equatable, Sendable { case unknown, macDVI, windowsHDMI }
    public enum Phase: Equatable, Sendable {
        case local
        case preparing(String)
        case switchingToWindows(String)
        case acquiring(String)
        case windows(String)
        case switchingToMac(String)
    }
    public private(set) var phase: Phase = .local
    public private(set) var displayInput: DisplayInput = .macDVI
    public private(set) var changedAt: TimeInterval = 0
    public private(set) var switchesDisplayOnEntry = true
    public private(set) var entryFractionY: Double = 0.5
    public init(displayInput: DisplayInput = .macDVI) { self.displayInput = displayInput }
    public var id: String? {
        switch phase {
        case .local: nil
        case .preparing(let id), .switchingToWindows(let id), .acquiring(let id),
             .windows(let id), .switchingToMac(let id): id
        }
    }
    public var ownsInput: Bool { if case .windows = phase { true } else { false } }
    public var inProgress: Bool { phase != .local }
    public var canEnterFromSamsung: Bool { displayInput == .windowsHDMI && phase == .local }

    /// Records a user-confirmed input or the completion of our serialized DDC
    /// write. It does not grant input ownership, even if an old write completed.
    public mutating func selectDisplay(_ input: DisplayInput) { displayInput = input }

    @discardableResult
    public mutating func begin(id: String = UUID().uuidString, switchDisplay: Bool = true,
                              fractionY: Double = 0.5, now: TimeInterval) -> String? {
        guard phase == .local, switchDisplay || displayInput == .windowsHDMI else { return nil }
        switchesDisplayOnEntry = switchDisplay
        entryFractionY = fractionY.isFinite ? min(1, max(0, fractionY)) : 0.5
        phase = .preparing(id); changedAt = now; return id
    }
    public mutating func prepared(_ replyID: String?, now: TimeInterval) -> Bool {
        guard case .preparing(let id) = phase, replyID == id else { return false }
        // Crossing back from Samsung requires input readiness, NOT another
        // video command, dwell timer, or flicker of the Philips panel.
        phase = switchesDisplayOnEntry ? .switchingToWindows(id) : .acquiring(id)
        changedAt = now; return true
    }
    public mutating func switched(_ replyID: String?, now: TimeInterval) -> Bool {
        guard case .switchingToWindows(let id) = phase, replyID == id else { return false }
        displayInput = .windowsHDMI
        phase = .acquiring(id); changedAt = now; return true
    }
    public mutating func acquired(_ replyID: String?, visible: Bool, now: TimeInterval) -> Bool {
        guard case .acquiring(let id) = phase, replyID == id, visible else { return false }
        phase = .windows(id); changedAt = now; return true
    }
    public mutating func releaseInput(_ replyID: String?, reason: String?, now: TimeInterval) -> Bool {
        guard case .windows(let id) = phase, replyID == id,
              reason == "left-edge" || reason == "window-close" || reason == "input-unavailable" else { return false }
        phase = .local; changedAt = now; return true
    }
    /// Call only for an explicit button/shortcut, after releasing input. Neither
    /// a peer's leave message nor inactivity can request a DVI command.
    public mutating func requestMacDisplay(id: String = UUID().uuidString, now: TimeInterval) -> String? {
        guard phase == .local else { return nil }
        phase = .switchingToMac(id); changedAt = now; return id
    }
    public mutating func returned(_ replyID: String?) -> Bool {
        guard case .switchingToMac(let id) = phase, replyID == id else { return false }
        displayInput = .macDVI; phase = .local; return true
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

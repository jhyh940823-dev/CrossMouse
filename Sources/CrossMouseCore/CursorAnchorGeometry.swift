import Foundation
import CoreGraphics

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

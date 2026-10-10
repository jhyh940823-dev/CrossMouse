/// Physical HID reports and desktop cursor relocation are separate inputs.
/// A transfer may consume only reports produced after ownership was accepted.
public struct PhysicalMotionCapture: Sendable {
    private var acceptedAfter: UInt64?
    public init() {}
    public mutating func begin(at timestamp: UInt64) { acceptedAfter = timestamp }
    public mutating func end() { acceptedAfter = nil }
    public func accepts(reportTimestamp: UInt64) -> Bool {
        guard let acceptedAfter else { return false }
        return reportTimestamp > acceptedAfter
    }
}

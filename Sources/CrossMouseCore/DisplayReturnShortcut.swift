/// A single ordinary F8 press requests DVI. Keep ownership of its key-up and
/// repeats even after input/display ownership returns to Mac, so one press
/// cannot leak into either foreground app or queue repeated monitor commands.
public struct DisplayReturnShortcut: Sendable {
    public enum Decision: Equatable, Sendable { case pass, consume, requestDVI }
    public static let keyCode = 0x64 // kVK_F8, independent of keyboard language
    private var capturedPress = false

    public init() {}

    public mutating func handle(keyCode: Int, down: Bool, isRepeat: Bool = false,
                                hasModifiers: Bool = false, enabled: Bool) -> Decision {
        guard keyCode == Self.keyCode else { return .pass }
        if !down {
            guard capturedPress else { return .pass }
            capturedPress = false
            return .consume
        }
        if capturedPress { return .consume }
        // Do not repurpose an F8 that began before this mode was enabled, or
        // modified F8 shortcuts belonging to another application.
        guard enabled, !hasModifiers, !isRepeat else { return .pass }
        capturedPress = true
        return .requestDVI
    }

    public mutating func reset() { capturedPress = false }
}

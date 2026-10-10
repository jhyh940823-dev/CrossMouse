/// A single ordinary F8 press requests DVI. Keep ownership of its key-up and
/// repeats even after input/display ownership returns to Mac, so one press
/// cannot leak into either foreground app or queue repeated monitor commands.
public struct DisplayReturnShortcut: Sendable {
    public enum Decision: Equatable, Sendable { case pass, consume, requestDVI }
    public enum Source: String, Hashable, Sendable { case functionF8, playPause }
    public static let keyCode = 0x64 // kVK_F8, independent of keyboard language
    private var capturedPresses = Set<Source>()

    public init() {}

    public mutating func handle(keyCode: Int, down: Bool, isRepeat: Bool = false,
                                hasModifiers: Bool = false, enabled: Bool) -> Decision {
        guard keyCode == Self.keyCode else { return .pass }
        return handle(source: .functionF8, down: down, isRepeat: isRepeat,
                      hasModifiers: hasModifiers, enabled: enabled)
    }

    public mutating func handle(source: Source, down: Bool, isRepeat: Bool = false,
                                hasModifiers: Bool = false, enabled: Bool) -> Decision {
        if !down {
            guard capturedPresses.remove(source) != nil else { return .pass }
            return .consume
        }
        if capturedPresses.contains(source) { return .consume }
        // Do not repurpose an F8 that began before this mode was enabled, or
        // modified F8 shortcuts belonging to another application.
        guard enabled, !hasModifiers, !isRepeat else { return .pass }
        capturedPresses.insert(source)
        return .requestDVI
    }

    public mutating func reset() { capturedPresses.removeAll() }
}

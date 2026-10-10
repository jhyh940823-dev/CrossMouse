import AppKit

@MainActor
final class HotCornerHUD {
    private var panel: NSPanel?
    private var label: NSTextField?

    func show(on screen: NSScreen, progress: Double) {
        if panel == nil {
            let window = NSPanel(
                contentRect: CGRect(x: 0, y: 0, width: 245, height: 48),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            window.isOpaque = false
            window.hasShadow = true
            window.backgroundColor = NSColor.black.withAlphaComponent(0.82)
            window.level = .floating
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.cornerRadius = 12
            let caption = NSTextField(labelWithString: "")
            caption.textColor = .white
            caption.font = .systemFont(ofSize: 12, weight: .semibold)
            caption.alignment = .center
            caption.frame = CGRect(x: 10, y: 12, width: 225, height: 25)
            window.contentView?.addSubview(caption)
            label = caption
            panel = window
        }
        guard let panel else { return }
        panel.setFrameOrigin(CGPoint(
            x: screen.frame.maxX - 270,
            y: screen.frame.maxY - 75
        ))
        let remaining = max(0, 1.25 * (1 - progress))
        label?.stringValue = String(format: "Windows로 전환까지 %.1f초", remaining)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

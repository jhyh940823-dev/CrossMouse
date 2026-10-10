import AppKit

/// A real, launchable macOS control window. Closing it quits the helper
/// so input interception cannot be left running invisibly.
@MainActor
final class MacControlWindow: NSWindowController, NSWindowDelegate {
    var onMacMode: (() -> Void)?
    var onWindowsMode: (() -> Void)?
    var onConnectionToggle: (() -> Void)?
    var onQuit: (() -> Void)?

    private let macButton = NSButton(radioButtonWithTitle: "Mac 듀얼 모니터 (DVI)", target: nil, action: nil)
    private let windowsButton = NSButton(radioButtonWithTitle: "Windows 사용 (HDMI)", target: nil, action: nil)
    private let connectionButton = NSButton(title: "연결 중지", target: nil, action: nil)
    private let quitButton = NSButton(title: "앱 종료", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Windows 연결 확인 중…")
    private let modeDescription = NSTextField(labelWithString: "")
    private let diagnosticsLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 515, height: 350),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CrossMouse"
        window.center()
        window.minSize = NSSize(width: 475, height: 325)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureWindow(window)
    }

    required init?(coder: NSCoder) { nil }

    private func configureWindow(_ window: NSWindow) {
        func text(_ string: String, size: CGFloat, bold: Bool = false) -> NSTextField {
            let field = NSTextField(labelWithString: string)
            field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
            return field
        }
        let title = text("CrossMouse", size: 23, bold: true)
        let subtitle = text("삼성 스마트 모니터 ↔ 필립스 271E1", size: 13)
        subtitle.textColor = .secondaryLabelColor
        let section = text("지금 필립스에 표시하는 화면", size: 15, bold: true)

        for field in [statusLabel, modeDescription, diagnosticsLabel] {
            field.font = .systemFont(ofSize: 13)
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
        }
        modeDescription.textColor = .secondaryLabelColor
        diagnosticsLabel.textColor = .secondaryLabelColor
        macButton.target = self
        macButton.action = #selector(selectMac)
        windowsButton.target = self
        windowsButton.action = #selector(selectWindows)
        connectionButton.target = self
        connectionButton.action = #selector(toggleConnection)
        connectionButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quit)
        quitButton.bezelStyle = .rounded

        let modeRow = NSStackView(views: [macButton, windowsButton])
        modeRow.orientation = .horizontal
        modeRow.spacing = 22
        let actionRow = NSStackView(views: [connectionButton, quitButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 12

        let note = text(
            "모니터 입력(DVI / HDMI)은 모니터 버튼으로 직접 바꾼 뒤, 여기서 같은 모드를 선택하세요. 창을 닫으면 앱도 종료됩니다.",
            size: 12
        )
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [
            title, subtitle, statusLabel, section, modeRow,
            modeDescription, diagnosticsLabel, actionRow, note
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18)
        ])
    }

    func render(connected: Bool, connecting: Bool, windowsMode: Bool,
                captureStatus: String) {
        macButton.state = windowsMode ? .off : .on
        windowsButton.state = windowsMode ? .on : .off
        statusLabel.stringValue = !connecting ? "Windows 연결 중지됨" :
            connected ? "Windows에 연결됨" : "Windows 연결 대기 중…"
        connectionButton.title = connecting ? "연결 중지" : "연결 시작"
        modeDescription.stringValue = windowsMode
            ? "삼성 오른쪽 끝 → 필립스 Windows, 왼쪽 끝 → Mac 복귀"
            : "Mac 듀얼 화면: 삼성에서 필립스로 커서가 정상 이동합니다."
        diagnosticsLabel.stringValue = captureStatus
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onQuit?()
    }

    @objc private func selectMac() { onMacMode?() }
    @objc private func selectWindows() { onWindowsMode?() }
    @objc private func toggleConnection() { onConnectionToggle?() }
    @objc private func quit() { onQuit?() }
}

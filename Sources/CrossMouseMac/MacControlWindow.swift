import AppKit

/// A real, launchable macOS control window. Closing only hides it;
/// the menu bar item continues to expose status and an explicit Quit action.
@MainActor
final class MacControlWindow: NSWindowController, NSWindowDelegate {
    var onMacMode: (() -> Void)?
    var onWindowsMode: (() -> Void)?
    var onConnectionToggle: (() -> Void)?
    var onQuit: (() -> Void)?
    var onHDMITest: (() -> Void)?
    var onDVITest: (() -> Void)?
    var onAutoSwitch: ((Bool) -> Void)?

    private let macButton = NSButton(radioButtonWithTitle: "Mac 듀얼 모니터 (DVI)", target: nil, action: nil)
    private let windowsButton = NSButton(radioButtonWithTitle: "Windows 사용 (HDMI)", target: nil, action: nil)
    private let connectionButton = NSButton(title: "연결 중지", target: nil, action: nil)
    private let quitButton = NSButton(title: "앱 종료", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Windows 연결 확인 중…")
    private let modeDescription = NSTextField(labelWithString: "")
    private let diagnosticsLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let ddcTestButton = NSButton(title: "HDMI 전환 시험", target: nil, action: nil)
    private let ddcReturnButton = NSButton(title: "DVI 복귀 시험", target: nil, action: nil)
    private let autoSwitchCheck = NSButton(
        checkboxWithTitle: "필립스 오른쪽 위 1.25초 머물면 Windows로 전환",
        target: nil, action: nil
    )
    private let monitorStatusLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 565, height: 465),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CrossMouse"
        window.minSize = NSSize(width: 550, height: 455)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        placeOnSamsung()
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
        ddcTestButton.target = self
        ddcTestButton.action = #selector(testHDMI)
        ddcTestButton.bezelStyle = .rounded
        ddcReturnButton.target = self
        ddcReturnButton.action = #selector(testDVI)
        ddcReturnButton.bezelStyle = .rounded
        autoSwitchCheck.target = self
        autoSwitchCheck.action = #selector(toggleAutoSwitch)
        autoSwitchCheck.font = .systemFont(ofSize: 12)
        monitorStatusLabel.font = .systemFont(ofSize: 12)
        monitorStatusLabel.textColor = .secondaryLabelColor
        monitorStatusLabel.maximumNumberOfLines = 0
        monitorStatusLabel.lineBreakMode = .byWordWrapping

        let modeRow = NSStackView(views: [macButton, windowsButton])
        modeRow.orientation = .horizontal
        modeRow.spacing = 22
        let actionRow = NSStackView(views: [connectionButton, quitButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 12
        let ddcRow = NSStackView(views: [ddcTestButton, ddcReturnButton])
        ddcRow.orientation = .horizontal
        ddcRow.spacing = 12

        noteLabel.stringValue = "X 버튼은 창만 숨깁니다. 앱은 상단 ⇆ 메뉴에서 다시 열 수 있고, '앱 종료'로 완전히 끕니다."
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 0
        noteLabel.lineBreakMode = .byWordWrapping
        let stack = NSStackView(views: [
            title, subtitle, statusLabel, section, modeRow,
            modeDescription, diagnosticsLabel, ddcRow,
            autoSwitchCheck, monitorStatusLabel, actionRow, noteLabel
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
                captureStatus: String, autoVerified: Bool = false,
                autoEnabled: Bool = false, monitorBusy: Bool = false,
                monitorStatus: String = "") {
        macButton.state = windowsMode ? .off : .on
        windowsButton.state = windowsMode ? .on : .off
        statusLabel.stringValue = !connecting ? "Windows 연결 중지됨" :
            connected ? "Windows에 연결됨" : "Windows 연결 대기 중…"
        connectionButton.title = connecting ? "연결 중지" : "연결 시작"
        modeDescription.stringValue = windowsMode
            ? "삼성 오른쪽 끝 → 필립스 Windows, 왼쪽 끝 → Mac 복귀"
            : "Mac 듀얼 화면: 삼성에서 필립스로 커서가 정상 이동합니다."
        diagnosticsLabel.stringValue = captureStatus
        ddcTestButton.isEnabled = !monitorBusy
        ddcReturnButton.isEnabled = !monitorBusy
        autoSwitchCheck.isEnabled = autoVerified && !monitorBusy
        autoSwitchCheck.state = autoVerified && autoEnabled ? .on : .off
        monitorStatusLabel.stringValue = monitorStatus.isEmpty
            ? "모니터 입력 자동 전환은 시험 성공 확인 후 사용할 수 있습니다."
            : monitorStatus
    }

    func show() {
        placeOnSamsung()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The Philips can immediately stop showing Mac video when a DDC test
    /// succeeds. Always keep settings and confirmation dialogs accessible
    /// on the Samsung Mac screen instead of the disappearing Philips.
    private func placeOnSamsung() {
        guard let window else { return }
        let samsung = NSScreen.screens.first {
            $0.localizedName.localizedCaseInsensitiveContains("Smart M70F")
                || $0.localizedName.localizedCaseInsensitiveContains("Samsung")
        } ?? NSScreen.main
        guard let samsung else {
            window.center()
            return
        }
        let visible = samsung.visibleFrame
        let frame = window.frame
        window.setFrameOrigin(CGPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        ))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc private func selectMac() { onMacMode?() }
    @objc private func selectWindows() { onWindowsMode?() }
    @objc private func toggleConnection() { onConnectionToggle?() }
    @objc private func quit() { onQuit?() }
    @objc private func testHDMI() { onHDMITest?() }
    @objc private func testDVI() { onDVITest?() }
    @objc private func toggleAutoSwitch() {
        onAutoSwitch?(autoSwitchCheck.state == .on)
    }
}

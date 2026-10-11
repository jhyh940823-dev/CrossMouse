import AppKit
import ApplicationServices
import CrossMouseCore
import Foundation

private struct Options {
    let host: String
    let port: UInt16
    let displayID: CGDirectDisplayID?
    let key: Data

    static func parse() throws -> Options {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            exit(0)
        }
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let configDirectory = NSHomeDirectory() + "/.config/crossmouse"
        let savedHost = try? String(
            contentsOfFile: configDirectory + "/host", encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = value("--host") ?? savedHost, !host.isEmpty else {
            printUsage()
            throw CrossMouseError.invalidHandshake
        }
        let port = UInt16(value("--port") ?? "49431")
        guard let port, port > 0 else { throw CrossMouseError.invalidHandshake }
        let displayID: CGDirectDisplayID?
        if let selected = value("--display-id") {
            guard let parsed = UInt32(selected) else { throw CrossMouseError.invalidHandshake }
            displayID = parsed
        } else {
            displayID = nil
        }
        let keyPath = value("--key-file") ?? configDirectory + "/key"
        let contents = try String(contentsOfFile: keyPath, encoding: .utf8)
        return Options(
            host: host, port: port, displayID: displayID,
            key: try CrossMouseWire.decodeKey(contents)
        )
    }

    static func printUsage() {
        print("""
        CrossMouseMac — a keyboard/mouse bridge to a paired Windows PC
        Usage: CrossMouseMac [--host <windows-ip>] [--port 49431] [--display-id N]
                              [--key-file ~/.config/crossmouse/key]

        Run CrossMouse.Windows on Windows first, copy its generated 64-character
        pairing key into ~/.config/crossmouse/key on this Mac (chmod 600).
        Put the Windows PC IPv4 address in ~/.config/crossmouse/host or pass --host.
        Enable Accessibility and Input Monitoring permissions for this executable
        or the Terminal app that launches it.
        """)
    }
}

@MainActor
private final class CrossMouseApp: NSObject, NSApplicationDelegate {
    private let options: Options
    private var network: MacConnection!
    private var connected = false
    private var connectionWanted = true
    private var receiverLiveness = ReceiverLiveness()
    private var heartbeatTimer: Timer?
    private var receiverResponsive = false
    private var awaitingEnterAt: TimeInterval?
    // This describes the Philips video input, NOT where the cursor is.
    private var windowsReady: Bool {
        get { automaticHandoff.displayInput == .windowsHDMI }
        set { rememberDisplayInput(newValue ? .windowsHDMI : .macDVI) }
    }
    private var remoteActive = false
    private var pressedModifiers = Set<Int>()
    private var statusItem: NSStatusItem!
    private var readyItem: NSMenuItem!
    private var statusLine: NSMenuItem!
    private var captureLine: NSMenuItem!
    private var transferLine: NSMenuItem!
    private var eventTap: CFMachPort?
    private var displayID: CGDirectDisplayID = 0
    private var displayBounds: CGRect = .zero
    private var remoteCursorAnchor: CGPoint?
    private var transferAttempts = 0
    private var lastTransfer = "No handoff attempted yet"
    private var controlWindow: MacControlWindow!
    private var macModeItem: NSMenuItem!
    private var windowsModeItem: NSMenuItem!
    private let monitorDDC = MacDDCInput()
    private let hotCornerHUD = HotCornerHUD()
    private var hotCornerGate = HotCornerGate(dwellSeconds: 1.25)
    private var hotCornerTimer: Timer?
    private var ddcBusy = false
    private var verifiedHDMI = UserDefaults.standard.bool(forKey: "CrossMouse.ddcVerifiedHDMI")
    private var verifiedDVI = UserDefaults.standard.bool(forKey: "CrossMouse.ddcVerifiedDVI")
    private var autoInputSwitch = UserDefaults.standard.bool(forKey: "CrossMouse.autoInputSwitch")
    private var monitorStatus = "DDC 입력 전환은 확인 후에만 활성화할 수 있습니다."
    // A process restart does not change the physical monitor to DVI.
    private var automaticHandoff = AutomaticHandoff(displayInput: .unknown)
    private var requestedMacDisplay = false
    private var displayReturnShortcut = DisplayReturnShortcut()
    private var lastShortcutStatus = ""
    private var focusRequestQueued = false
    private var pointerMotion = PointerMotionScale(percent:
        (UserDefaults.standard.object(forKey: "CrossMouse.windowsPointerSpeedPercent") as? NSNumber)?.doubleValue
            ?? PointerMotionScale.defaultPercent)
    private var peerCapability: String?
    private var peerVersion = "확인되지 않음"
    private var peerStatus = ""
    private let physicalPointer = MacPhysicalPointer()
    private var launchedInBackground = false

    init(options: Options) {
        self.options = options
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedInBackground = MacLoginItem.isBackgroundLaunch(
            arguments: CommandLine.arguments,
            event: NSAppleEventManager.shared().currentAppleEvent
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMenu()
        setupWindow()
        launchedInBackground = launchedInBackground || MacLoginItem.isBackgroundLaunch(
            arguments: CommandLine.arguments,
            event: NSAppleEventManager.shared().currentAppleEvent
        )
        refreshDisplay()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplay() }
        }

        network = MacConnection(
            host: options.host, port: options.port, secret: options.key,
            onConnected: { [weak self] value in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.connected = value
                    self.peerCapability = nil
                    self.peerStatus = ""
                    self.receiverLiveness.reset()
                    self.receiverResponsive = false
                    if !value {
                        self.cancelAutomaticEntry()
                        self.reclaimMac()
                    }
                    else { self.network.send(CrossMouseMessage(type: "ping")) }
                    self.updateMenu()
                }
            },
            onMessage: { [weak self] message in
                if message.transferId != nil {
                    DispatchQueue.main.async { self?.receiveAutomaticMessage(message) }
                    return
                }
                if message.type == "pong" {
                    DispatchQueue.main.async {
                        guard let self, self.connected, self.connectionWanted else { return }
                        self.peerCapability = message.capability
                        self.peerVersion = message.version ?? "이전 수신기"
                        let peerStatus = "Windows \(self.peerVersion) · "
                            + (message.serviceMode.map { $0 ? "로그인 전 서비스" : "로그인 후 앱" } ?? "실행 방식 미확인")
                            + (message.inputDesktop.map { " · " + String($0.prefix(64)) } ?? "")
                            + (message.pointerState.map { " · " + String($0.prefix(100)) } ?? "")
                        let peerStatusChanged = self.peerStatus != peerStatus
                        self.peerStatus = peerStatus
                        self.receiverLiveness.confirm(
                            at: ProcessInfo.processInfo.systemUptime
                        )
                        if !self.receiverResponsive {
                            self.receiverResponsive = true
                            self.updateMenu()
                        } else if peerStatusChanged {
                            self.updateMenu()
                        }
                    }
                } else if message.type == "entered" {
                    DispatchQueue.main.async {
                        guard let self, self.remoteActive,
                              !self.automaticHandoff.inProgress, self.awaitingEnterAt != nil else { return }
                        self.awaitingEnterAt = nil
                        self.lastTransfer = "Windows confirmed remote control"
                        self.updateMenu()
                    }
                } else if message.type == "rejected" {
                    DispatchQueue.main.async {
                        guard let self, !self.automaticHandoff.inProgress else { return }
                        self.reclaimMac()
                        self.lastTransfer = "Windows rejected mouse control"
                        self.monitorStatus = "Windows가 커서 제어를 받지 못했습니다. Windows 앱 상태를 확인하세요."
                        self.updateMenu()
                    }
                } else if message.type == "leave" {
                    DispatchQueue.main.async {
                        // Unidentified/legacy replies have no authority over
                        // an automatic monitor transaction.
                        guard let self, !self.automaticHandoff.inProgress else { return }
                        self.lastTransfer = "Windows requested return to Mac"
                        self.reclaimMac()
                        self.updateMenu()
                    }
                }
            }
        )
        network.start()
        installEventTap()
        physicalPointer.onMotion = { [weak self] dx, dy in
            guard let self, self.remoteActive, self.automaticHandoff.ownsInput else { return }
            self.sendInput(CrossMouseMessage(type: "move", dx: dx, dy: dy))
        }
        physicalPointer.start()
        monitorDDC.readInput { [weak self] input in
            guard let self, self.automaticHandoff.displayInput == .unknown,
                  !self.automaticHandoff.inProgress, !self.ddcBusy else { return }
            if let input {
                self.rememberDisplayInput(input == .hdmi ? .windowsHDMI : .macDVI)
                self.monitorStatus = "모니터 입력 읽기: \(input == .hdmi ? "HDMI" : "DVI")"
            } else if let saved = UserDefaults.standard.string(forKey: "CrossMouse.lastSelectedInput"),
                      saved == "HDMI" || saved == "DVI" {
                self.automaticHandoff.restoreDisplaySelection(saved == "HDMI" ? .windowsHDMI : .macDVI)
                self.monitorStatus = "마지막 선택 \(saved) · 실제 입력 읽기 불가. F8로 Mac 복귀는 계속 사용할 수 있습니다."
            } else {
                self.monitorStatus = "현재 영상 입력 확인 불가 · F8로 Mac(DVI) 복귀 가능. 화면 모드를 선택해 주세요."
            }
            self.traceTransfer("startup-display", id: nil, reason: input.map { String($0.rawValue) } ?? "unknown")
            self.updateMenu()
        }
        updateMenu()
        refreshLoginItemStatus()
        if !launchedInBackground { controlWindow.show() }
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickHotCorner() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hotCornerTimer = timer
        // A disconnected/stalled Windows receiver can leave the Mac cursor
        // parked at the edge. TCP 'connected' isn't a sufficient health check.
        // Ping periodically and reclaim locally on missing app-level pong.
        let heartbeat = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkReceiverHeartbeat() }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        heartbeatTimer = heartbeat
        NSLog("CrossMouse: Mac boundary display ID %u, bounds %@", displayID, NSStringFromRect(displayBounds))
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelAutomaticEntry()
        network?.send(CrossMouseMessage(type: "leave"))
        network?.stop()
        physicalPointer.stop()
        reclaimMac()
        hotCornerTimer?.invalidate()
        heartbeatTimer?.invalidate()
        hotCornerHUD.hide()
        if let eventTap { CFMachPortInvalidate(eventTap) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        refreshLoginItemStatus()
        controlWindow.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func setupWindow() {
        controlWindow = MacControlWindow()
        controlWindow.onMacMode = { [weak self] in self?.requestMacDisplay() }
        controlWindow.onWindowsMode = { [weak self] in self?.selectWindowsMode() }
        controlWindow.onConnectionToggle = { [weak self] in self?.toggleConnection() }
        controlWindow.onQuit = { [weak self] in self?.quitApp() }
        controlWindow.onHDMITest = { [weak self] in self?.testMonitorInput(.hdmi) }
        controlWindow.onDVITest = { [weak self] in self?.testMonitorInput(.dvi) }
        controlWindow.onAutoSwitch = { [weak self] enabled in self?.setAutoInputSwitch(enabled) }
        controlWindow.onDVIRequest = { [weak self] in self?.requestMacDisplay() }
        controlWindow.onPointerSpeed = { [weak self] value in self?.setPointerSpeed(value) }
        controlWindow.onLoginItem = { [weak self] enabled in self?.setLoginItem(enabled) }
        controlWindow.onLoginSettings = { MacLoginItem.openSettings() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if controlWindow != nil { refreshLoginItemStatus() }
    }

    private func refreshLoginItemStatus(error: String? = nil) {
        let status = MacLoginItem.status
        let message: String
        if let error { message = "자동 실행 설정 실패: " + error }
        else {
            switch status {
            case .enabled: message = "등록됨 · 로그인 후 창 없이 연결합니다. 앱 위치를 옮기지 마세요."
            case .requiresApproval: message = "승인 필요 · macOS 로그인 항목 설정에서 허용해 주세요."
            case .notRegistered: message = "꺼짐 · 체크하면 이 Mac 계정의 로그인 항목에 등록합니다."
            case .notFound: message = "앱을 고정된 위치에서 실행한 뒤 다시 등록해 주세요."
            @unknown default: message = "시스템 로그인 항목 설정에서 상태를 확인해 주세요."
            }
        }
        controlWindow.renderLoginItem(
            enabled: status == .enabled, awaitingApproval: status == .requiresApproval,
            message: message
        )
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            try MacLoginItem.setEnabled(enabled)
            refreshLoginItemStatus()
        } catch { refreshLoginItemStatus(error: error.localizedDescription) }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⇆"
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        captureLine = NSMenuItem(title: "Input capture: checking", action: nil, keyEquivalent: "")
        captureLine.isEnabled = false
        menu.addItem(captureLine)
        transferLine = NSMenuItem(title: "No handoff attempted yet", action: nil, keyEquivalent: "")
        transferLine.isEnabled = false
        menu.addItem(transferLine)
        menu.addItem(.separator())
        let showWindow = NSMenuItem(title: "CrossMouse 창 열기", action: #selector(showWindowAction), keyEquivalent: "")
        showWindow.target = self
        menu.addItem(showWindow)
        macModeItem = NSMenuItem(title: "Mac 듀얼 모니터 (필립스 DVI)", action: #selector(selectMacMode), keyEquivalent: "")
        macModeItem.target = self
        menu.addItem(macModeItem)
        windowsModeItem = NSMenuItem(title: "Windows 사용 (필립스 HDMI)", action: #selector(selectWindowsMode), keyEquivalent: "")
        windowsModeItem.target = self
        menu.addItem(windowsModeItem)
        readyItem = NSMenuItem(
            title: "Windows on right edge", action: #selector(toggleReady), keyEquivalent: ""
        )
        readyItem.target = self
        readyItem.isEnabled = false
        menu.addItem(readyItem)
        let returnItem = NSMenuItem(
            title: "Return keyboard/mouse to Mac", action: #selector(returnToMac),
            keyEquivalent: ""
        )
        returnItem.target = self
        menu.addItem(returnItem)
        let dviReturn = NSMenuItem(title: "필립스를 Mac 화면(DVI)으로 · F8",
                                  action: #selector(requestMacDisplay), keyEquivalent: "")
        dviReturn.target = self
        menu.addItem(dviReturn)
        menu.addItem(.separator())
        let help = NSMenuItem(title: "Emergency return: Ctrl+Option+Shift+Esc", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)
        let retry = NSMenuItem(title: "Retry input capture", action: #selector(retryInputCapture), keyEquivalent: "")
        retry.target = self
        menu.addItem(retry)
        let settings = NSMenuItem(title: "Open input permission settings", action: #selector(openInputSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit CrossMouse", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func showWindowAction() {
        refreshLoginItemStatus()
        controlWindow.show()
    }

    @objc private func selectMacMode() {
        requestMacDisplay()
    }

    @objc private func selectWindowsMode() {
        guard !windowsReady else { updateMenu(); return }
        guard verifiedHDMI && verifiedDVI else {
            monitorStatus = "먼저 HDMI 전환 시험과 DVI 복귀 시험을 확인해 주세요."
            updateMenu(); return
        }
        _ = beginWindowsFocus(switchDisplay: true)
    }

    private func setWindowsMode(_ enable: Bool) {
        requestedMacDisplay = false
        cancelAutomaticEntry()
        hotCornerGate.reset()
        hotCornerHUD.hide()
        if !enable {
            // Always inform Windows to release held keys and buttons, even
            // if the handoff recently returned to Mac by moving left.
            network?.send(CrossMouseMessage(type: "leave"))
            reclaimMac()
        }
        windowsReady = enable
        updateMenu()
    }

    private func checkReceiverHeartbeat() {
        if let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) {
            // Restore the owned tap after an OS timeout; never leave a non-null
            // but disabled tap reported as installed. No key value is recorded.
            displayReturnShortcut.reset()
            if remoteActive { forceReturn() }
            CGEvent.tapEnable(tap: eventTap, enable: true)
            traceTransfer("input-tap-reenabled", id: nil)
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        let wasResponsive = receiverResponsive
        receiverResponsive = connected && connectionWanted
            && receiverLiveness.isResponsive(at: uptime)
        let enterTimedOut = remoteActive && (awaitingEnterAt.map {
            uptime - $0 > 1.5
        } ?? false)
        if remoteActive && (!receiverResponsive || enterTimedOut) {
            // Even if TCP is half-open or the Windows process stopped
            // consuming events, the Mac MUST release its local cursor.
            // Disarm automatic re-entry until the user deliberately retries.
            cancelAutomaticEntry()
            network.send(CrossMouseMessage(type: "leave"))
            reclaimMac()
            lastTransfer = enterTimedOut
                ? "Windows entry not acknowledged — safely returned to Mac"
                : "Windows stopped responding — safely returned to Mac"
            monitorStatus = enterTimedOut
                ? "Windows가 커서 진입을 확인하지 않아 Mac으로 복귀했습니다. Windows 앱을 확인하세요."
                : "Windows 수신기 응답이 없어 Mac 커서를 복구했습니다. Windows 앱을 확인하세요."
            updateMenu()
        } else if wasResponsive != receiverResponsive {
            updateMenu()
        }
        if connectionWanted && connected {
            network.send(CrossMouseMessage(type: "ping"))
        }
    }

    @objc private func toggleReady() {
        if windowsReady { requestMacDisplay() }
        else { selectWindowsMode() }
    }

    private func setAutoInputSwitch(_ enabled: Bool) {
        cancelAutomaticEntry()
        autoInputSwitch = enabled && verifiedHDMI && verifiedDVI
        UserDefaults.standard.set(autoInputSwitch, forKey: "CrossMouse.autoInputSwitch")
        hotCornerGate.reset()
        hotCornerHUD.hide()
        monitorStatus = autoInputSwitch
            ? "오른쪽 위 1.25초 → HDMI. 이후 좌우 커서 이동은 HDMI를 유지합니다. F8 한 번 → Mac 화면(DVI)."
            : "자동 입력 전환 꺼짐. HDMI와 DVI 시험 모두 성공 확인 후 켤 수 있습니다."
        updateMenu()
    }

    private func testMonitorInput(_ target: MacDDCInput.Input) {
        guard !ddcBusy, !requestedMacDisplay, !automaticHandoff.inProgress else { return }
        controlWindow.show()
        let alert = NSAlert()
        alert.messageText = target == .hdmi ? "필립스 HDMI 전환을 시험할까요?" : "필립스 DVI 복귀를 시험할까요?"
        alert.informativeText = """
        모니터 영상이 바뀌거나 잠시 꺼질 수 있습니다. 삼성 Mac 화면은 그대로 유지됩니다.
        명령을 무시하는 모니터도 있으니 필립스 자체 입력 버튼으로 언제든 복구할 준비를 해주세요.
        최초 자동 전환 기능은 실제 성공을 확인하기 전까지 켜지지 않습니다.
        """
        alert.addButton(withTitle: "전환 시험")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        monitorStatus = "필립스 입력 전환 명령을 보내는 중…"
        ddcBusy = true
        updateMenu()
        monitorDDC.send(target) { [weak self] result in
            guard let self else { return }
            self.ddcBusy = false
            switch result {
            case .failure(let error):
                self.monitorStatus = "DDC 전환 실패: \(error.localizedDescription)"
            case .success:
                let confirm = NSAlert()
                confirm.messageText = "필립스 화면이 실제로 바뀌었나요?"
                confirm.informativeText = """
                DDC 명령은 성공으로 반환돼도 모니터가 무시할 수 있습니다.
                실제로 \(target == .hdmi ? "Windows HDMI" : "Mac DVI") 화면이 나타났을 때만 '전환됨'을 눌러주세요.
                """
                confirm.addButton(withTitle: "전환됨")
                confirm.addButton(withTitle: "전환 안 됨")
                if confirm.runModal() == .alertFirstButtonReturn {
                    self.setWindowsMode(target == .hdmi)
                    if target == .hdmi {
                        self.verifiedHDMI = true
                        UserDefaults.standard.set(true, forKey: "CrossMouse.ddcVerifiedHDMI")
                    } else {
                        self.verifiedDVI = true
                        UserDefaults.standard.set(true, forKey: "CrossMouse.ddcVerifiedDVI")
                    }
                    self.monitorStatus = "필립스 \(target == .hdmi ? "HDMI" : "DVI") 전환 성공 확인됨"
                } else {
                    self.monitorStatus = "모니터가 명령을 무시했거나 입력이 확인되지 않았습니다. 수동 입력 전환을 사용하세요."
                }
            }
            self.updateMenu()
        }
    }

    private func tickHotCorner() {
        if requestedMacDisplay {
            if !ddcBusy { performMacDisplayRequest() }
            return
        }
        if automaticHandoff.inProgress {
            if automaticHandoff.expired(at: ProcessInfo.processInfo.systemUptime) {
                cancelAutomaticEntry()
                monitorStatus = "전환 확인 응답이 오지 않았습니다. 입력은 Mac에 있습니다."
                updateMenu()
            }
            return
        }
        guard connectionWanted, connected, receiverResponsive, !windowsReady, !remoteActive,
              autoInputSwitch, verifiedHDMI, verifiedDVI, !ddcBusy, eventTap != nil,
              let philips = NSScreen.screens.first(where: {
                  $0.localizedName.localizedCaseInsensitiveContains("PHL 271E1")
              }),
              let number = philips.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let pointer = CGEvent(source: nil)?.location
        else {
            hotCornerGate.reset()
            hotCornerHUD.hide()
            return
        }

        let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        let inside = pointer.x >= bounds.maxX - 20
            && pointer.x < bounds.maxX + 1
            && pointer.y >= bounds.minY
            && pointer.y <= bounds.minY + 120
        let phase = hotCornerGate.update(
            inside: inside, now: ProcessInfo.processInfo.systemUptime,
            enabled: true
        )
        switch phase {
        case .idle:
            hotCornerHUD.hide()
        case .holding(let fraction):
            hotCornerHUD.show(on: philips, progress: fraction)
        case .triggered:
            hotCornerHUD.hide()
            _ = beginWindowsFocus(switchDisplay: true)
        }
    }

    @discardableResult
    private func beginWindowsFocus(switchDisplay: Bool, fractionY: Double = 0.5) -> Bool {
        guard !ddcBusy, !requestedMacDisplay, !remoteActive,
              connected, connectionWanted, receiverResponsive else { return false }
        guard peerCapability == "handoff-2" else {
            monitorStatus = "Windows \(peerVersion): 화면·커서 준비 확인 기능이 없습니다. 수동 공유는 그대로 사용할 수 있습니다."
            updateMenu(); return false
        }
        guard physicalPointer.canCapture else {
            monitorStatus = "물리 마우스 입력을 확인하지 못했습니다. 동글 연결과 입력 권한을 확인하세요."
            updateMenu(); return false
        }
        guard let id = automaticHandoff.begin(switchDisplay: switchDisplay, fractionY: fractionY,
                                               now: ProcessInfo.processInfo.systemUptime) else { return false }
        pointerMotion.reset()
        monitorStatus = switchDisplay ? "Windows의 대상 화면과 입력 준비를 확인하는 중…"
            : "필립스 HDMI 유지 · Windows 커서 연결 중…"
        traceTransfer(switchDisplay ? "prepare-with-HDMI" : "prepare-input-only", id: id)
        network.send(CrossMouseMessage(type: "prepare", transferId: id))
        updateMenu()
        return true
    }

    private func sendPreparedEntry(_ id: String) {
        guard automaticHandoff.phase == .acquiring(id) else { return }
        network.send(CrossMouseMessage(type: "enter", fractionY: automaticHandoff.entryFractionY,
            centerCursor: automaticHandoff.switchesDisplayOnEntry, transferId: id))
    }

    private func cancelAutomaticEntry() {
        if let id = automaticHandoff.cancel() {
            traceTransfer("cancel", id: id)
            network?.send(CrossMouseMessage(type: "leave", transferId: id, reason: "cancel"))
            // Cancelling input never claims that the physical input changed.
            // A later Samsung crossing uses a NEW prepared, correlated owner.
            reclaimMac()
        }
    }

    private func receiveAutomaticMessage(_ message: CrossMouseMessage) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let id = message.transferId, id == automaticHandoff.id else {
            traceTransfer("ignored-stale-\(message.type)", id: message.transferId)
            return
        }
        traceTransfer("receive-\(message.type)", id: id, reason: message.reason)
        switch message.type {
        case "prepared":
            guard automaticHandoff.prepared(id, now: now), connected, connectionWanted else { return }
            if automaticHandoff.phase == .acquiring(id) {
                // Philips is already showing Windows: no DDC call, no dwell.
                sendPreparedEntry(id)
                updateMenu()
                return
            }
            ddcBusy = true
            CGWarpMouseCursorPosition(CGPoint(x: displayBounds.midX, y: displayBounds.midY))
            monitorStatus = "Windows 준비 확인됨 · 필립스 HDMI 전환 중…"
            monitorDDC.send(.hdmi) { [weak self] result in
                guard let self else { return }
                self.ddcBusy = false
                // DDC work is serialized. Its physical result remains true if
                // the user cancelled input ownership while the write ran.
                if case .success = result { self.rememberDisplayInput(.windowsHDMI) }
                guard self.automaticHandoff.id == id else { return }
                switch result {
                case .success:
                    guard self.automaticHandoff.switched(id, now: ProcessInfo.processInfo.systemUptime) else { return }
                    self.traceTransfer("HDMI-command-completed", id: id)
                    self.monitorStatus = "Windows 화면과 커서 표시 확인 중 · 입력은 아직 Mac에 있습니다."
                    self.sendPreparedEntry(id)
                case .failure(let error):
                    self.cancelAutomaticEntry()
                    self.monitorStatus = "HDMI 명령 실패: \(error.localizedDescription)"
                }
                self.updateMenu()
            }
        case "entered":
            guard automaticHandoff.acquired(id, visible: message.pointerVisible == true, now: now) else { return }
            let anchor = CGPoint(x: displayBounds.maxX - 5, y: displayBounds.midY)
            guard CGWarpMouseCursorPosition(anchor) == .success else {
                cancelAutomaticEntry(); monitorStatus = "Mac 커서 제어를 확보하지 못했습니다."; updateMenu(); return
            }
            remoteCursorAnchor = anchor
            remoteActive = true
            pointerMotion.reset()
            physicalPointer.beginCapture()
            awaitingEnterAt = nil
            transferAttempts += 1
            lastTransfer = "Windows ownership and cursor presentation confirmed"
            monitorStatus = "Windows 제어 중 · \(message.reason ?? "준비 확인됨")"
            traceTransfer("ownership-committed", id: id)
        case "leave":
            guard automaticHandoff.releaseInput(id, reason: message.reason, now: now) else { return }
            reclaimMac()
            lastTransfer = "Mac input focus · Philips stays HDMI"
            monitorStatus = "커서만 Mac으로 복귀 · 필립스는 Windows 유지. 삼성 오른쪽 끝에서 다시 Windows로 이동합니다."
            traceTransfer("input-return-HDMI-retained", id: id, reason: message.reason)
        case "rejected":
            cancelAutomaticEntry()
            monitorStatus = "Windows가 입력을 받지 않았습니다: \(message.reason ?? "사유 없음")"
        default: break
        }
        updateMenu()
    }

    @objc private func requestMacDisplay() {
        // This explicit action is the ONLY automatic DVI command. It works
        // from either computer's input focus and even if the peer is offline.
        if case .switchingToMac = automaticHandoff.phase { return }
        guard verifiedDVI else {
            monitorStatus = "먼저 DVI 복귀 시험으로 모니터 동작을 확인해 주세요."
            updateMenu(); return
        }
        requestedMacDisplay = true
        cancelAutomaticEntry()
        network?.send(CrossMouseMessage(type: "leave")) // release legacy/manual owner too
        reclaimMac()
        hotCornerGate.reset(); hotCornerHUD.hide()
        if ddcBusy {
            monitorStatus = "진행 중인 화면 명령이 끝나면 요청한 DVI 복귀를 실행합니다."
        } else { performMacDisplayRequest() }
        updateMenu()
    }

    private func performMacDisplayRequest() {
        guard requestedMacDisplay, !ddcBusy,
              let id = automaticHandoff.requestMacDisplay(now: ProcessInfo.processInfo.systemUptime) else { return }
        requestedMacDisplay = false
        ddcBusy = true
        monitorStatus = "요청한 DVI 복귀 실행 중 · 입력은 Mac에 있습니다."
        traceTransfer("explicit-DVI-request", id: id)
        monitorDDC.send(.dvi) { [weak self] result in
            guard let self else { return }
            self.ddcBusy = false
            if case .success = result { self.rememberDisplayInput(.macDVI) }
            guard self.automaticHandoff.id == id else { self.updateMenu(); return }
            switch result {
            case .success:
                _ = self.automaticHandoff.returned(id)
                self.monitorStatus = "Mac 듀얼 화면으로 복귀했습니다. 오른쪽 위 카운트다운으로 다시 HDMI에 진입합니다."
                self.traceTransfer("explicit-DVI-completed", id: id)
            case .failure(let error):
                self.cancelAutomaticEntry()
                self.monitorStatus = "DVI 명령 실패: \(error.localizedDescription). 입력은 Mac에 있습니다."
            }
            self.hotCornerGate.reset()
            self.updateMenu()
        }
    }

    private func rememberDisplayInput(_ input: AutomaticHandoff.DisplayInput) {
        automaticHandoff.selectDisplay(input)
        if input != .unknown {
            UserDefaults.standard.set(input == .windowsHDMI ? "HDMI" : "DVI", forKey: "CrossMouse.lastSelectedInput")
        }
    }

    private func setPointerSpeed(_ value: Double) {
        pointerMotion.setPercent(value)
        UserDefaults.standard.set(pointerMotion.percent, forKey: "CrossMouse.windowsPointerSpeedPercent")
        controlWindow.renderPointerSpeed(pointerMotion.percent)
    }

    private func traceTransfer(_ event: String, id: String?, reason: String? = nil) {
        // Causality only: never keys, clipboard, pairing secrets or user motion.
        NSLog("CrossMouse handoff id=%@ event=%@ reason=%@", id ?? "none", event, reason ?? "none")
        DiagnosticTrace.shared.record(event, id: id, reason: reason)
    }

    private func sendInput(_ message: CrossMouseMessage) {
        var input = message
        if input.type == "move" {
            let scaled = pointerMotion.apply(dx: input.dx ?? 0, dy: input.dy ?? 0)
            guard scaled.dx != 0 || scaled.dy != 0 else { return }
            input.dx = scaled.dx; input.dy = scaled.dy
        }
        if automaticHandoff.ownsInput { input.transferId = automaticHandoff.id }
        network.send(input)
    }

    @objc private func toggleConnection() {
        if connectionWanted {
            cancelAutomaticEntry()
            // Pausing must release Windows input, but must not forget that
            // the user selected HDMI. Otherwise pressing Start silently
            // reverts to Mac mode and the cursor cannot cross the boundary.
            network.send(CrossMouseMessage(type: "leave"))
            reclaimMac()
            connectionWanted = false
            connected = false
            receiverLiveness.reset()
            receiverResponsive = false
            network.stop()
        } else {
            connectionWanted = true
            receiverLiveness.reset()
            receiverResponsive = false
            network.start()
        }
        updateMenu()
    }

    @objc private func returnToMac() {
        forceReturn()
    }

    @objc private func quitApp() {
        forceReturn()
        NSApp.terminate(nil)
    }

    @objc private func retryInputCapture() {
        if eventTap == nil { installEventTap() }
        updateMenu()
    }

    @objc private func openInputSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateMenu() {
        statusLine.title = !connectionWanted ? "Connection paused" :
            connected ? (!receiverResponsive ? "Windows receiver not responding" :
                remoteActive ? "Windows is controlling" : "Windows receiver ready") :
            "Windows disconnected"
        if let eventTap, CGEvent.tapIsEnabled(tap: eventTap) {
            captureLine.title = "Input capture installed"
        } else if !AXIsProcessTrusted() {
            captureLine.title = "Input capture unavailable: Accessibility not granted"
        } else if !CGPreflightListenEventAccess() {
            captureLine.title = "Input capture unavailable: Input Monitoring not granted"
        } else {
            captureLine.title = "Input capture unavailable: retry or restart app"
        }
        transferLine.title = lastTransfer
        readyItem.state = windowsReady ? .on : .off
        macModeItem.state = windowsReady ? .off : .on
        windowsModeItem.state = windowsReady ? .on : .off
        statusItem.button?.title = remoteActive ? "⇆ W" : "⇆"
        controlWindow?.render(
            connected: connected, connecting: connectionWanted,
            windowsMode: windowsReady, captureStatus: captureLine.title + (lastShortcutStatus.isEmpty ? "" : " · " + lastShortcutStatus)
                + (peerStatus.isEmpty ? "" : "\n" + peerStatus),
            receiverResponsive: receiverResponsive,
            autoVerified: verifiedHDMI && verifiedDVI, autoEnabled: autoInputSwitch,
            monitorBusy: ddcBusy, monitorStatus: monitorStatus,
            displayKnown: automaticHandoff.hasCurrentDisplaySelection
        )
        controlWindow?.renderPointerSpeed(pointerMotion.percent)
    }

    private func refreshDisplay() {
        let previous = CursorAnchorGeometry(displayID: displayID, bounds: displayBounds)
        if let explicit = options.displayID {
            displayID = explicit
        } else if let samsung = NSScreen.screens.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains("samsung")
                || $0.localizedName.localizedCaseInsensitiveContains("Smart M70F")
        }), let number = samsung.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            displayID = CGDirectDisplayID(number.uint32Value)
        } else {
            displayID = CGMainDisplayID()
        }
        displayBounds = CGDisplayBounds(displayID)
        let next = CursorAnchorGeometry(displayID: displayID, bounds: displayBounds)
        // HDMI/DVI notifications about Philips are expected. Only reclaim
        // if Samsung (where the Mac cursor is actually parked) changed.
        if remoteActive && previous.requiresReclaim(after: next, online: CGDisplayIsOnline(displayID) != 0) {
            forceReturn()
            lastTransfer = "Mac anchor display changed — returned to Mac"
            updateMenu()
        }
    }

    private func installEventTap() {
        guard eventTap == nil else { return }
        if !AXIsProcessTrusted() {
            NSLog("CrossMouse: Accessibility permission is required. Grant it in System Settings and restart.")
        }
        if !CGPreflightListenEventAccess() {
            NSLog("CrossMouse: Input Monitoring permission is required. Grant it in System Settings and restart.")
        }
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
            .keyDown, .keyUp, .flagsChanged
        ]
        let mask = types.reduce(DisplayReturnEvent.eventMask) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: crossMouseEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("CrossMouse: cannot create input event tap. Enable Accessibility/Input Monitoring, then relaunch.")
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        updateMenu()
    }

    private func forceReturn() {
        requestedMacDisplay = false
        cancelAutomaticEntry()
        network.send(CrossMouseMessage(type: "leave"))
        reclaimMac()
    }

    private func reclaimMac() {
        physicalPointer.endCapture()
        pointerMotion.reset()
        awaitingEnterAt = nil
        guard remoteActive else { return }
        remoteActive = false
        remoteCursorAnchor = nil
        pressedModifiers.removeAll()
        let point = CGPoint(
            x: displayBounds.maxX - min(90, displayBounds.width / 4),
            y: displayBounds.midY
        )
        CGWarpMouseCursorPosition(point)
        updateMenu()
    }

    fileprivate func handleEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The keyboard and pointer must never remain remotely controlled
            // without a working interception tap.
            if remoteActive { forceReturn() }
            displayReturnShortcut.reset()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if let shortcutEvent = DisplayReturnEvent(type: type, event: event) {
            let decision = shortcutEvent.apply(
                to: &displayReturnShortcut,
                enabled: verifiedDVI && (automaticHandoff.needsDisplayReturnShortcut || requestedMacDisplay)
            )
            switch decision {
            case .requestDVI:
                traceTransfer("DVI-key-\(shortcutEvent.source.rawValue)", id: automaticHandoff.id)
                lastShortcutStatus = "F8 수신됨"
                // Never run DDC, window layout or ownership cleanup inside an
                // input-tap callback: the OS may disable a slow callback.
                DispatchQueue.main.async { [weak self] in self?.requestMacDisplay() }
                return nil
            case .consume: return nil
            case .pass: break
            }
        }
        // Adding systemDefined to the event mask must not swallow volume,
        // brightness, eject, or a play key that was not captured for DVI.
        if type == DisplayReturnEvent.systemDefinedType { return Unmanaged.passUnretained(event) }
        let shortcutFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
        if type == .keyDown && event.flags.intersection(shortcutFlags) == shortcutFlags {
            if keyCode == 53 { // Ctrl+Option+Shift+Escape: emergency local return.
                forceReturn()
                return nil
            }
            if keyCode == 111 { // Ctrl+Option+Shift+F12: Windows-ready toggle.
                toggleReady()
                return nil
            }
        }

        guard connectionWanted, connected, receiverResponsive, windowsReady else {
            if !remoteActive { keepLocalCursorOnSamsung(event, type: type) }
            return Unmanaged.passUnretained(event)
        }
        if automaticHandoff.inProgress && !automaticHandoff.ownsInput {
            keepLocalCursorOnSamsung(event, type: type)
            return Unmanaged.passUnretained(event)
        }
        if !remoteActive {
            // Only enter on an unpressed mouse move, not while dragging a file.
            if type == .mouseMoved,
               event.location.y >= displayBounds.minY,
               event.location.y < displayBounds.maxY,
               event.location.x >= displayBounds.maxX - 3,
               event.getIntegerValueField(.mouseEventDeltaX) > 0 {
                let ratio = min(1, max(0, (event.location.y - displayBounds.minY) / displayBounds.height))
                if peerCapability == "handoff-2" {
                    if !focusRequestQueued {
                        focusRequestQueued = true
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.focusRequestQueued = false
                            _ = self.beginWindowsFocus(switchDisplay: false, fractionY: ratio)
                        }
                    }
                    keepLocalCursorOnSamsung(event, type: type)
                    return nil
                }
                // Suppressing a session-level mouse event does not prevent
                // WindowServer from updating the *local* cursor position.
                // Keep the Mac pointer parked while forwarding relative deltas.
                // Unlike global cursor disassociation, this cannot leave a
                // user's pointer permanently disconnected if the app crashes.
                let anchor = CGPoint(
                    x: displayBounds.maxX - 5,
                    y: min(max(event.location.y, displayBounds.minY + 2), displayBounds.maxY - 2)
                )
                guard CGWarpMouseCursorPosition(anchor) == .success else {
                    lastTransfer = "Mac cursor lock failed — stayed on Mac"
                    updateMenu()
                    return Unmanaged.passUnretained(event)
                }
                remoteActive = true
                pointerMotion.reset()
                awaitingEnterAt = ProcessInfo.processInfo.systemUptime
                transferAttempts += 1
                lastTransfer = "Entered Windows (attempt \(transferAttempts))"
                remoteCursorAnchor = anchor
                network.send(CrossMouseMessage(type: "enter", fractionY: ratio))
                updateMenu()
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = Int(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = Int(event.getIntegerValueField(.mouseEventDeltaY))
            if !automaticHandoff.ownsInput && (dx != 0 || dy != 0) {
                sendInput(CrossMouseMessage(type: "move", dx: dx, dy: dy))
            }
            // Returning nil prevents local app delivery, but not all pointer
            // motion at the session tap. Reposition after each captured delta.
            // CGWarpMouseCursorPosition itself does not generate mouse events.
            if let anchor = remoteCursorAnchor {
                if CGWarpMouseCursorPosition(anchor) != .success {
                    lastTransfer = "Mac cursor lock failed — returned to Mac"
                    forceReturn()
                }
            }
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            let button: Int
            if type == .leftMouseDown || type == .leftMouseUp { button = 0 }
            else if type == .rightMouseDown || type == .rightMouseUp { button = 1 }
            else { button = Int(event.getIntegerValueField(.mouseEventButtonNumber)) }
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            sendInput(CrossMouseMessage(type: "button", button: button, down: down))
        case .scrollWheel:
            let v = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let h = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            if v != 0 || h != 0 {
                sendInput(CrossMouseMessage(type: "wheel", vertical: v, horizontal: h))
            }
        case .keyDown, .keyUp:
            sendInput(CrossMouseMessage(type: "key", down: type == .keyDown, code: keyCode))
        case .flagsChanged:
            let down = !pressedModifiers.contains(keyCode)
            if down { pressedModifiers.insert(keyCode) }
            else { pressedModifiers.remove(keyCode) }
            sendInput(CrossMouseMessage(type: "key", down: down, code: keyCode))
        default:
            break
        }
        return nil // Suppress all captured input while Windows has control.
    }

    private func keepLocalCursorOnSamsung(_ event: CGEvent, type: CGEventType) {
        guard windowsReady, type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged,
              event.location.x >= displayBounds.maxX - 3 else { return }
        // While readiness is pending the pointer must not disappear onto the
        // still-connected but invisible Mac desktop behind the Philips HDMI.
        let local = CGPoint(x: displayBounds.maxX - 5,
            y: min(displayBounds.maxY - 2, max(displayBounds.minY + 2, event.location.y)))
        CGWarpMouseCursorPosition(local)
        event.location = local
    }
}

private let crossMouseEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let shouldPass = MainActor.assumeIsolated {
        Unmanaged<CrossMouseApp>.fromOpaque(userInfo).takeUnretainedValue()
            .handleEvent(type, event) != nil
    }
    return shouldPass ? Unmanaged.passUnretained(event) : nil
}

do {
    if CommandLine.arguments.contains("--startup-self-test") {
        let passed = MacLoginItem.selfTest()
        print(passed ? "PASS Mac login launch classification (no registration changes)" : "FAIL Mac startup classification")
        exit(passed ? 0 : 1)
    }
    let options = try Options.parse()
    let delegate = CrossMouseApp(options: options)
    let application = NSApplication.shared
    application.delegate = delegate
    application.run()
} catch {
    fputs("CrossMouseMac: \(error.localizedDescription)\n", stderr)
    exit(2)
}

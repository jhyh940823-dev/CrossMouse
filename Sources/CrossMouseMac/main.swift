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
    private var windowsReady = false
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

    init(options: Options) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMenu()
        setupWindow()
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
                    self?.connected = value
                    if !value { self?.reclaimMac() }
                    self?.updateMenu()
                }
            },
            onMessage: { [weak self] message in
                if message.type == "leave" {
                    DispatchQueue.main.async {
                        self?.lastTransfer = "Windows requested return to Mac"
                        self?.reclaimMac()
                        self?.updateMenu()
                    }
                }
            }
        )
        network.start()
        installEventTap()
        updateMenu()
        controlWindow.show()
        NSLog("CrossMouse: Mac boundary display ID %u, bounds %@", displayID, NSStringFromRect(displayBounds))
    }

    func applicationWillTerminate(_ notification: Notification) {
        network?.send(CrossMouseMessage(type: "leave"))
        network?.stop()
        reclaimMac()
        if let eventTap { CFMachPortInvalidate(eventTap) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controlWindow.show()
        return true
    }

    private func setupWindow() {
        controlWindow = MacControlWindow()
        controlWindow.onMacMode = { [weak self] in self?.setWindowsMode(false) }
        controlWindow.onWindowsMode = { [weak self] in self?.setWindowsMode(true) }
        controlWindow.onConnectionToggle = { [weak self] in self?.toggleConnection() }
        controlWindow.onQuit = { [weak self] in self?.quitApp() }
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
        controlWindow.show()
    }

    @objc private func selectMacMode() {
        setWindowsMode(false)
    }

    @objc private func selectWindowsMode() {
        setWindowsMode(true)
    }

    private func setWindowsMode(_ enable: Bool) {
        if !enable {
            // Always inform Windows to release held keys and buttons, even
            // if the handoff recently returned to Mac by moving left.
            network?.send(CrossMouseMessage(type: "leave"))
            reclaimMac()
        }
        windowsReady = enable
        updateMenu()
    }

    @objc private func toggleReady() {
        setWindowsMode(!windowsReady)
    }

    @objc private func toggleConnection() {
        if connectionWanted {
            setWindowsMode(false)
            connectionWanted = false
            network.stop()
        } else {
            connectionWanted = true
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
            connected ? (remoteActive ? "Windows is controlling" : "Connected to Windows") :
            "Windows disconnected"
        if eventTap != nil {
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
            windowsMode: windowsReady, captureStatus: captureLine.title
        )
    }

    private func refreshDisplay() {
        // A monitor being reconfigured while Windows is active invalidates
        // the parked cursor's geometry. Give control back to Mac first.
        if remoteActive { forceReturn() }
        if let explicit = options.displayID {
            displayID = explicit
        } else if let samsung = NSScreen.screens.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains("samsung")
        }), let number = samsung.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            displayID = CGDirectDisplayID(number.uint32Value)
        } else {
            displayID = CGMainDisplayID()
        }
        displayBounds = CGDisplayBounds(displayID)
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
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
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
        network.send(CrossMouseMessage(type: "leave"))
        reclaimMac()
    }

    private func reclaimMac() {
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
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
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

        guard connected, windowsReady else { return Unmanaged.passUnretained(event) }
        if !remoteActive {
            // Only enter on an unpressed mouse move, not while dragging a file.
            if type == .mouseMoved,
               event.location.y >= displayBounds.minY,
               event.location.y < displayBounds.maxY,
               event.location.x >= displayBounds.maxX - 3,
               event.getIntegerValueField(.mouseEventDeltaX) > 0 {
                let ratio = min(1, max(0, (event.location.y - displayBounds.minY) / displayBounds.height))
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
            if dx != 0 || dy != 0 {
                network.send(CrossMouseMessage(type: "move", dx: dx, dy: dy))
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
            network.send(CrossMouseMessage(type: "button", button: button, down: down))
        case .scrollWheel:
            let v = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let h = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            if v != 0 || h != 0 {
                network.send(CrossMouseMessage(type: "wheel", vertical: v, horizontal: h))
            }
        case .keyDown, .keyUp:
            network.send(CrossMouseMessage(type: "key", down: type == .keyDown, code: keyCode))
        case .flagsChanged:
            let down = !pressedModifiers.contains(keyCode)
            if down { pressedModifiers.insert(keyCode) }
            else { pressedModifiers.remove(keyCode) }
            network.send(CrossMouseMessage(type: "key", down: down, code: keyCode))
        default:
            break
        }
        return nil // Suppress all captured input while Windows has control.
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
    let options = try Options.parse()
    let delegate = CrossMouseApp(options: options)
    let application = NSApplication.shared
    application.delegate = delegate
    application.run()
} catch {
    fputs("CrossMouseMac: \(error.localizedDescription)\n", stderr)
    exit(2)
}

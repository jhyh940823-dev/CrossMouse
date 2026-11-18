import AppKit
import Foundation

// Native integration fixture. All pasteboards are uniquely named and contain
// synthetic data. No .general access, key injection, pairing, network, or UI.
private struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

private func fixtureOutput(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

private final class DelayedProvider: NSObject, NSPasteboardItemDataProvider {
    let delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        fixtureOutput("requested")
        Thread.sleep(forTimeInterval: delay)
        item.setString("synthetic delayed clipboard", forType: type)
    }
}

@MainActor
private final class ProviderProcess {
    let name = "CrossMouse-test-responsiveness-" + UUID().uuidString
    let process = Process()
    private let output = Pipe()
    private(set) var requested = false

    init(delay: TimeInterval) throws {
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--provider", name, String(delay)]
        process.standardOutput = output
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            line.append(byte)
        }
        guard String(data: line, encoding: .utf8) == "ready" else {
            stop()
            throw FixtureFailure(description: "Delayed provider did not become ready")
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if String(data: data, encoding: .utf8)?.contains("requested") == true {
                DispatchQueue.main.async { self?.requested = true }
            }
        }
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        NSPasteboard(name: .init(name)).releaseGlobally()
    }
}

@MainActor
private final class ReadState {
    var outcome: TextClipboardReadProcess.Outcome?
    var callbacks = 0
    var elapsed: Double?
    var sentinel: Double?
}

@main
@MainActor
private struct ClipboardResponsivenessRegression {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw FixtureFailure(description: message) }
    }

    static func pump(until condition: () -> Bool, seconds: TimeInterval = 3) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw FixtureFailure(description: "Native fixture deadline exceeded")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    static func pause(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func read(_ reader: TextClipboardReadProcess, board: NSPasteboard,
                     acknowledged: Int? = nil) throws -> MacTextClipboard.ReadResult {
        let state = ReadState()
        reader.read(acknowledgedChange: acknowledged, boardName: board.name.rawValue) {
            state.callbacks += 1
            state.outcome = $0
        }
        try pump(until: { state.outcome != nil })
        guard case .read(let value) = state.outcome else {
            throw FixtureFailure(description: "Expected clipboard read, received \(String(describing: state.outcome))")
        }
        try require(state.callbacks == 1, "A read delivered more than one completion")
        return value
    }

    static func delayedDeadline(executable: URL) throws {
        let provider = try ProviderProcess(delay: 2)
        defer { provider.stop() }
        let reader = TextClipboardReadProcess(executableURL: executable, timeout: 1)
        defer { reader.cancel() }
        let state = ReadState()
        let start = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            state.sentinel = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        reader.read(acknowledgedChange: nil, boardName: provider.name) {
            state.callbacks += 1
            state.outcome = $0
            state.elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        try pump(until: { state.outcome != nil && state.sentinel != nil })
        guard case .timedOut = state.outcome else {
            throw FixtureFailure(description: "Slow native provider did not time out: \(String(describing: state.outcome))")
        }
        try require(provider.requested, "Helper never reached the native delayed provider")
        try require(state.sentinel! < 200, "Main loop stalled while native clipboard helper waited")
        try require(state.elapsed! >= 800 && state.elapsed! < 1600, "Read deadline was not bounded near one second")
        pause(1.2)
        try require(state.callbacks == 1, "Timed-out helper delivered a late result")
        fixtureOutput(String(format: "PASS delayed native provider: main sentinel %.2f ms, bounded timeout %.2f ms, no late result", state.sentinel!, state.elapsed!))
    }

    static func cancellationAndReplacement(executable: URL) throws {
        let provider = try ProviderProcess(delay: 2)
        defer { provider.stop() }
        let fresh = NSPasteboard(name: .init("CrossMouse-test-fresh-" + UUID().uuidString))
        defer { fresh.releaseGlobally() }
        fresh.clearContents()
        try require(fresh.setString("fresh copy immediately after cancel", forType: .string), "Fixture write failed")
        let reader = TextClipboardReadProcess(executableURL: executable, timeout: 1)
        defer { reader.cancel() }
        let cancelled = ReadState()
        reader.read(acknowledgedChange: nil, boardName: provider.name) {
            cancelled.callbacks += 1
            cancelled.outcome = $0
        }
        try pump(until: { provider.requested }, seconds: 1)
        reader.cancel()
        let start = ProcessInfo.processInfo.systemUptime
        let result = try read(reader, board: fresh)
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        guard case .text(let snapshot) = result else { throw FixtureFailure(description: "Replacement copy not delivered") }
        try require(snapshot.text == "fresh copy immediately after cancel", "Replacement copy was stale")
        try require(elapsed < 800, "Fresh copy waited for the cancelled provider deadline")
        pause(2.1)
        try require(cancelled.callbacks == 0, "Cancelled native read delivered a callback")
        fixtureOutput(String(format: "PASS cancel during native provider request: fresh copy %.2f ms, cancelled callback count 0", elapsed))
    }

    static func repeatedCopiesAndBounds(executable: URL) throws {
        let board = NSPasteboard(name: .init("CrossMouse-test-cycles-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let reader = TextClipboardReadProcess(executableURL: executable, timeout: 1)
        defer { reader.cancel() }
        var acknowledged: Int?
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<20 {
            let text = "synthetic copy \(index) — 한글🙂\nsecond line"
            board.clearContents()
            try require(board.setString(text, forType: .string), "Cycle fixture write failed")
            guard case .text(let snapshot) = try read(reader, board: board, acknowledged: acknowledged) else {
                throw FixtureFailure(description: "Fresh copy \(index) was not available immediately")
            }
            try require(snapshot.text == text, "Cycle \(index) returned a stale copy")
            acknowledged = snapshot.changeCount
        }
        guard case .unchanged = try read(reader, board: board, acknowledged: acknowledged) else {
            throw FixtureFailure(description: "Acknowledged unchanged copy was retransmitted")
        }
        fixtureOutput(String(format: "PASS 20 immediate distinct Unicode copies and acknowledged unchanged result: %.2f ms", (ProcessInfo.processInfo.systemUptime - start) * 1000))

        let unit = "한글🙂\n"
        let maximum = TextClipboardWire.maxBytes
        let exact = String(repeating: unit, count: maximum / unit.utf8.count)
            + String(repeating: "x", count: maximum % unit.utf8.count)
        try require(exact.utf8.count == maximum, "Maximum-size fixture is wrong")
        board.clearContents(); board.setString(exact, forType: .string)
        guard case .text(let snapshot) = try read(reader, board: board) else {
            throw FixtureFailure(description: "Exact 256 KiB Unicode text was rejected")
        }
        try require(snapshot.text == exact, "Maximum-size text was truncated or altered")
        board.clearContents(); board.setString(exact + "x", forType: .string)
        guard case .tooLarge = try read(reader, board: board) else {
            throw FixtureFailure(description: "Over-limit text was not rejected")
        }
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                       "org.nspasteboard.AutoGeneratedType", "org.nspasteboard.RemoteClipboardType", "public.file-url"] {
            board.declareTypes([.string, .init(marker)], owner: nil)
            board.setString("synthetic excluded fixture", forType: .string)
            board.setData(Data(), forType: .init(marker))
            guard case .excluded = try read(reader, board: board) else {
                throw FixtureFailure(description: "Protected/file marker was not excluded: \(marker)")
            }
        }
        fixtureOutput("PASS exact 256 KiB Unicode, oversize rejection, five protected/file markers through production helper")
    }

    static func noHelperChildren() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while true {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-P", String(ProcessInfo.processInfo.processIdentifier), "-f", "read-text-clipboard"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            if process.terminationStatus == 1 { break }
            try require(process.terminationStatus == 0, "Unable to verify owned helper cleanup")
            try require(ProcessInfo.processInfo.systemUptime < deadline, "Owned clipboard helper remained after completion/cancellation")
            pause(0.02)
        }
        fixtureOutput("PASS all owned production clipboard helper children reaped")
    }

    static func providerMain(name: String, delay: TimeInterval) {
        precondition(name.hasPrefix("CrossMouse-test-"))
        let board = NSPasteboard(name: .init(name))
        let provider = DelayedProvider(delay: delay)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        board.clearContents()
        precondition(board.writeObjects([item]))
        fixtureOutput("ready")
        withExtendedLifetime((board, provider, item)) {
            RunLoop.main.run(until: Date().addingTimeInterval(12))
        }
        board.releaseGlobally()
    }

    static func main() {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--provider",
           let delay = Double(CommandLine.arguments[3]) {
            providerMain(name: CommandLine.arguments[2], delay: delay)
            return
        }
        do {
            try require(CommandLine.arguments.count == 2, "Pass the built CrossMouseMac executable path")
            let executable = URL(fileURLWithPath: CommandLine.arguments[1])
            try delayedDeadline(executable: executable)
            try cancellationAndReplacement(executable: executable)
            try repeatedCopiesAndBounds(executable: executable)
            try noHelperChildren()
            fixtureOutput("PASS native clipboard responsiveness integration; named synthetic pasteboards only")
        } catch {
            // A failed assertion still lets cancellation reap the helper owned
            // by the case's reader; the fixture must not leave a child behind.
            try? noHelperChildren()
            FileHandle.standardError.write(Data(("FAIL native clipboard responsiveness: \(error)\n").utf8))
            exit(1)
        }
    }
}

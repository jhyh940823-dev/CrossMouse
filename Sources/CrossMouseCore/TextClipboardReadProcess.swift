import AppKit
import Darwin
import Foundation

/// A slow pasteboard owner must not occupy the input event-tap run loop. A
/// single owned, short-lived copy of this executable performs the native read
/// on its own main thread. Cancellation can therefore stop the actual IPC,
/// rather than merely abandoning a still-blocked Swift task/thread.
@MainActor
public final class TextClipboardReadProcess {
    public enum Outcome: Sendable {
        case read(MacTextClipboard.ReadResult), timedOut, busy, failed
    }

    private let worker: Worker
    private var current: UUID?

    public init(executableURL: URL, timeout: TimeInterval = 1) {
        worker = Worker(executableURL: executableURL, timeout: max(0.01, timeout))
    }

    public func read(acknowledgedChange: Int?, boardName: String? = nil,
                     completion: @escaping @MainActor @Sendable (Outcome) -> Void) {
        let id = UUID()
        current = id
        worker.submit(acknowledgedChange: acknowledgedChange, boardName: boardName) { [weak self] outcome in
            Task { @MainActor in
                guard let self, self.current == id else { return }
                self.current = nil
                completion(outcome)
            }
        }
    }

    public func cancel() {
        current = nil
        worker.cancel()
    }

    deinit { worker.cancel() }

    /// Called before normal app/options initialization: no pairing key,
    /// network connection, input tap, UI, or clipboard mutation in this mode.
    /// nil board name is the sole production path to the general pasteboard;
    /// a supplied test name is never silently replaced with the general board.
    public static func runHelperIfRequested(arguments: [String]) -> Int32? {
        guard arguments.dropFirst().contains("--read-text-clipboard") else { return nil }
        guard Thread.isMainThread else { return 2 }
        var name: String?
        var acknowledged: Int?
        var sawMode = false
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--read-text-clipboard":
                guard !sawMode else { return 2 }
                sawMode = true
            case "--pasteboard-name":
                index += 1
                guard index < arguments.count, name == nil,
                      !arguments[index].isEmpty, arguments[index].utf8.count <= 256 else { return 2 }
                name = arguments[index]
            case "--acknowledged-change":
                index += 1
                guard index < arguments.count, acknowledged == nil,
                      let value = Int(arguments[index]), value >= 0 else { return 2 }
                acknowledged = value
            default: return 2
            }
            index += 1
        }
        var outputInfo = stat()
        guard fstat(STDOUT_FILENO, &outputInfo) == 0,
              outputInfo.st_mode & S_IFMT == S_IFIFO else { return 2 }
        return autoreleasepool {
            let reader = MacTextClipboard()
            if let acknowledged { reader.acknowledge(changeCount: acknowledged) }
            let board = name.map { NSPasteboard(name: .init($0)) } ?? .general
            let envelope = Envelope(reader.read(board))
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes]
                let data = try encoder.encode(envelope)
                guard data.count <= Envelope.maximumBytes else { return 3 }
                try FileHandle.standardOutput.write(contentsOf: data)
                return 0
            } catch { return 3 }
        }
    }
}

private struct Envelope: Codable {
    enum Kind: String, Codable { case text, unchanged, unavailable, excluded, tooLarge }
    let kind: Kind
    let changeCount: Int?
    let utf8: Data?
    // Base64 has a predictable size; arbitrary copied text never expands into
    // unbounded JSON escaping, arguments, files, errors, or diagnostics.
    static let maximumBytes = ((TextClipboardWire.maxBytes + 2) / 3) * 4 + 1024

    init(_ result: MacTextClipboard.ReadResult) {
        switch result {
        case .text(let snapshot):
            kind = .text; changeCount = snapshot.changeCount; utf8 = Data(snapshot.text.utf8)
        case .unchanged: kind = .unchanged; changeCount = nil; utf8 = nil
        case .unavailable: kind = .unavailable; changeCount = nil; utf8 = nil
        case .excluded: kind = .excluded; changeCount = nil; utf8 = nil
        case .tooLarge: kind = .tooLarge; changeCount = nil; utf8 = nil
        }
    }

    var result: MacTextClipboard.ReadResult? {
        switch kind {
        case .text:
            guard let changeCount, changeCount >= 0, let utf8, !utf8.isEmpty,
                  utf8.count <= TextClipboardWire.maxBytes, !utf8.contains(0),
                  let text = String(data: utf8, encoding: .utf8) else { return nil }
            return .text(.init(changeCount: changeCount, text: text))
        case .unchanged: return .unchanged
        case .unavailable: return .unavailable
        case .excluded: return .excluded
        case .tooLarge: return .tooLarge
        }
    }
}

/// All mutable process/pipe state belongs exclusively to queue. Cross-queue
/// closures only enqueue work; they never inspect a Job. The child's termination
/// handler retains Worker until cleanup, including after its public owner dies.
private final class Worker: @unchecked Sendable {
    private final class Job: @unchecked Sendable {
        let acknowledged: Int?
        let boardName: String?
        let deadline: DispatchTime
        let completion: @Sendable (TextClipboardReadProcess.Outcome) -> Void
        var process: Process?
        var output = Data()
        var pipe: Pipe?
        var reader: DispatchSourceRead?
        var timer: DispatchSourceTimer?
        var killer: DispatchSourceTimer?
        var cancelled = false
        var delivered = false
        var outputEOF = false
        init(acknowledged: Int?, boardName: String?, timeout: TimeInterval,
             completion: @escaping @Sendable (TextClipboardReadProcess.Outcome) -> Void) {
            self.acknowledged = acknowledged; self.boardName = boardName
            deadline = .now() + timeout; self.completion = completion
        }
    }
    private let executableURL: URL
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "io.crossmouse.clipboard-read")
    private var active: Job?
    private var pending: Job?

    init(executableURL: URL, timeout: TimeInterval) {
        self.executableURL = executableURL; self.timeout = timeout
    }

    func submit(acknowledgedChange: Int?, boardName: String?,
                completion: @escaping @Sendable (TextClipboardReadProcess.Outcome) -> Void) {
        let job = Job(acknowledged: acknowledgedChange, boardName: boardName,
                      timeout: timeout, completion: completion)
        queue.async { [self] in
            discardPending()
            armDeadline(job)
            if let active {
                pending = job
                stop(active)
            } else { launch(job) }
        }
    }

    func cancel() {
        queue.async { [self] in
            discardPending()
            if let active { stop(active) }
        }
    }

    private func discardPending() {
        pending?.cancelled = true
        pending?.timer?.cancel()
        pending = nil
    }

    private func armDeadline(_ job: Job) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: job.deadline)
        timer.setEventHandler { [weak self, weak job] in
            guard let self, let job, !job.cancelled else { return }
            deliver(.timedOut, for: job)
            if pending === job { pending = nil; job.timer?.cancel() }
            else if active === job { stop(job) }
        }
        job.timer = timer
        timer.resume()
    }

    private func launch(_ job: Job) {
        guard !job.cancelled, DispatchTime.now() < job.deadline else {
            deliver(.timedOut, for: job); job.timer?.cancel(); return
        }
        active = job
        let process = Process()
        let pipe = Pipe()
        job.process = process; job.pipe = pipe
        process.executableURL = executableURL
        var args = ["--read-text-clipboard"]
        if let name = job.boardName { args += ["--pasteboard-name", name] }
        if let count = job.acknowledged { args += ["--acknowledged-change", String(count)] }
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [self, weak job] _ in
            guard let job else { return }
            queue.async { [self] in childExited(job) }
        }
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) >= 0 else {
            deliver(.failed, for: job); finish(job); return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak job] in
            if let self, let job { drain(job) }
        }
        source.setCancelHandler { try? pipe.fileHandleForReading.close() }
        job.reader = source
        source.resume()
        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
        } catch {
            deliver(.failed, for: job)
            finish(job)
        }
    }

    private func drain(_ job: Job) {
        guard !job.cancelled, !job.outputEOF, let pipe = job.pipe else { return }
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        // Even a malformed child cannot monopolize the deadline/kill queue.
        for _ in 0..<32 {
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count <= 0 {
                if count < 0 && errno == EINTR { continue }
                if count == 0 { closeOutput(job) }
                return
            }
            guard job.output.count + count <= Envelope.maximumBytes else {
                deliver(.failed, for: job); stop(job); return
            }
            job.output.append(contentsOf: bytes.prefix(count))
        }
    }

    private func childExited(_ job: Job) {
        guard active === job else { return }
        drain(job)
        if !job.cancelled {
            if DispatchTime.now() >= job.deadline {
                deliver(.timedOut, for: job)
            } else if job.process?.terminationReason == .exit, job.process?.terminationStatus == 0,
               let result = (try? JSONDecoder().decode(Envelope.self, from: job.output))?.result {
                deliver(.read(result), for: job)
            } else { deliver(.failed, for: job) }
        }
        finish(job)
    }

    private func deliver(_ outcome: TextClipboardReadProcess.Outcome, for job: Job) {
        guard !job.delivered, !job.cancelled else { return }
        job.delivered = true
        job.completion(outcome)
    }

    private func stop(_ job: Job) {
        guard active === job, !job.cancelled else { return }
        job.cancelled = true
        job.output.removeAll(keepingCapacity: false)
        job.timer?.cancel()
        closeOutput(job)
        guard let process = job.process, process.isRunning else { return }
        process.terminate()
        let killer = DispatchSource.makeTimerSource(queue: queue)
        killer.schedule(deadline: .now() + 0.1)
        killer.setEventHandler { [weak self, weak job] in
            guard let self, let job, active === job,
                  let process = job.process, process.isRunning else { return }
            // Never signal a name-matched or unrelated process: this is only
            // the still-running child represented by our live Process object.
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        job.killer = killer
        killer.resume()
    }

    private func closeOutput(_ job: Job) {
        guard !job.outputEOF else { return }
        job.outputEOF = true
        job.reader?.cancel()
        job.reader = nil
    }

    private func finish(_ job: Job) {
        job.timer?.cancel(); job.killer?.cancel()
        closeOutput(job)
        job.process?.terminationHandler = nil
        try? job.pipe?.fileHandleForWriting.close()
        job.pipe = nil; job.output.removeAll(keepingCapacity: false)
        guard active === job else { return }
        active = nil
        if let next = pending { pending = nil; launch(next) }
    }
}

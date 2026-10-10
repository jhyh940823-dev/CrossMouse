import AppKit
import Foundation

/// Optional monitor-input backend for Apple silicon. It intentionally uses a
/// separate m1ddc executable rather than a bundled IOKit private API.
/// No input switching occurs until the user explicitly runs a test and
/// confirms that the *physical* Philips monitor changed input successfully.
@MainActor
final class MacDDCInput {
    enum Input: Int {
        case dvi = 3   // Standard MCCS input select: DVI-1
        case hdmi = 17 // Standard MCCS input select: HDMI-1
    }

    enum SwitchError: LocalizedError {
        case missingTool
        case monitorMissing
        case multipleMonitors
        case timedOut
        case failed

        var errorDescription: String? {
            switch self {
            case .missingTool: return "m1ddc를 찾을 수 없습니다. Mac에서 'brew install m1ddc'가 필요합니다."
            case .monitorMissing: return "DDC에서 PHL 271E1 모니터를 찾을 수 없습니다."
            case .multipleMonitors: return "같은 이름의 필립스 모니터가 둘 이상이므로 자동 조작하지 않습니다."
            case .timedOut: return "필립스 모니터 DDC 통신 시간이 초과됐습니다."
            case .failed: return "필립스가 해당 입력 전환 명령을 받지 못했습니다."
            }
        }
    }

    nonisolated private static let toolPaths = [
        "/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"
    ]
    private let worker = DispatchQueue(label: "CrossMouse.philips-DDC", qos: .userInitiated)

    func readInput(completion: @escaping @MainActor (Input?) -> Void) {
        worker.async {
            let input: Input?
            do {
                let tool = try Self.toolPath()
                let display = try Self.resolveDisplay(tool)
                let response = try Self.execute(tool, arguments: ["display", display, "get", "input"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                input = Int(response).flatMap(Input.init(rawValue:))
            } catch { input = nil }
            Task { @MainActor in completion(input) }
        }
    }

    nonisolated private static func resolveDisplay(_ tool: String) throws -> String {
        let list = try execute(tool, arguments: ["display", "list"])
        let matches = list.split(separator: "\n").compactMap { line -> String? in
            guard line.localizedCaseInsensitiveContains("PHL 271E1"),
                  let left = line.firstIndex(of: "("), let right = line.firstIndex(of: ")"), left < right
            else { return nil }
            let uuid = String(line[line.index(after: left)..<right])
            return UUID(uuidString: uuid) == nil ? nil : uuid
        }
        guard !matches.isEmpty else { throw SwitchError.monitorMissing }
        guard matches.count == 1 else { throw SwitchError.multipleMonitors }
        return matches[0]
    }

    func send(_ input: Input, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        worker.async {
            let result: Result<Void, Error>
            do {
                let tool = try Self.toolPath()
                let display = try Self.resolveDisplay(tool)
                _ = try Self.execute(tool, arguments: [
                    "display", display, "set", "input", String(input.rawValue)
                ])
                result = .success(())
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in completion(result) }
        }
    }

    nonisolated private static func toolPath() throws -> String {
        guard let path = toolPaths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw SwitchError.missingTool
        }
        return path
    }

    nonisolated private static func execute(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // m1ddc emits only small status lines. Wait for bounded process lifetime
        // BEFORE a blocking EOF read. A stuck helper cannot latch ddcBusy forever.
        if exited.wait(timeout: .now() + 4) == .timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            try? output.fileHandleForReading.close()
            throw SwitchError.timedOut
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw process.terminationReason == .uncaughtSignal
                ? SwitchError.timedOut : SwitchError.failed
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

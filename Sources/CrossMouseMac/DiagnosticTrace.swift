import Foundation

/// Bounded operational journal. Never receives ordinary keys, pointer samples,
/// clipboard contents, credentials, or foreground window titles.
final class DiagnosticTrace: @unchecked Sendable {
    static let shared = DiagnosticTrace()
    private let queue = DispatchQueue(label: "CrossMouse.diagnostics", qos: .utility)
    private let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CrossMouse", isDirectory: true)
    func record(_ event: String, id: String? = nil, reason: String? = nil) {
        let observedAt = Date()
        queue.async { [self] in
            do {
                let record: [String: String] = ["event": String(event.prefix(100)),
                    "id": String((id ?? "none").prefix(80)), "reason": String((reason ?? "none").prefix(240)),
                    "time": ISO8601DateFormatter().string(from: observedAt)]
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent("diagnostics.jsonl")
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 131072 {
                    let old = directory.appendingPathComponent("diagnostics.previous.jsonl")
                    try? FileManager.default.removeItem(at: old)
                    try FileManager.default.moveItem(at: url, to: old)
                }
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil,
                        attributes: [.posixPermissions: 0o600])
                }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd()
                var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                line.append(10)
                try file.write(contentsOf: line)
            } catch { /* A diagnostic failure cannot interrupt input ownership. */ }
        }
    }
}

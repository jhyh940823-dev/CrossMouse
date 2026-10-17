import Foundation

/// This file is only a connection hint. The key is neither read nor changed.
/// A concurrent manual address edit is preserved, not overwritten by discovery.
public final class PeerAddressStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var expectedHost: String
    public init(url: URL, expectedHost: String) { self.url = url; self.expectedHost = expectedHost }
    public func saveVerifiedHost(_ host: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard LocalPeerSubnet.address(host) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 256 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let current = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == expectedHost || current == host else { throw CocoaError(.fileWriteFileExists) }
        try (host + "\n").write(to: url, atomically: true, encoding: .utf8)
        expectedHost = host
    }
}

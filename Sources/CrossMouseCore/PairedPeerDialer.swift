import CryptoKit
import Foundation
import Network

public struct PeerEndpoint: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public let interface: NWInterface?
    public init(host: String, port: UInt16, interface: NWInterface? = nil) {
        self.host = host; self.port = port; self.interface = interface
    }
}

/// A socket is handed to the caller only AFTER the existing pairing challenge
/// and a fresh encrypted ping/pong. These counters include that ping and pong.
/// The caller must keep using `queue`, retain the socket, and resume receiving.
public struct AuthenticatedPeer: @unchecked Sendable {
    public let endpoint: PeerEndpoint
    public let connection: NWConnection
    public let sessionKey: Data
    public let firstPong: CrossMouseMessage
    public let remainingBytes: FramedByteBuffer
    public let sendSequence: UInt64 = 1
    public let receiveSequence: UInt64 = 1
}

/// Single-queue, bounded establishment only. It never sends input/clipboard,
/// writes settings, changes the monitor, or touches a working connection.
/// cancel(), start() and callbacks are serialized on the supplied queue.
public final class PairedPeerDialer: @unchecked Sendable {
    public enum Progress: Sendable { case connecting(String), searching(Int), exhausted }
    private final class Attempt {
        let endpoint: PeerEndpoint
        let socket: NWConnection
        let nonce = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        var buffer = FramedByteBuffer()
        var key: Data?
        var timer: DispatchWorkItem?
        init(endpoint: PeerEndpoint, socket: NWConnection) { self.endpoint = endpoint; self.socket = socket }
    }
    private let queue: DispatchQueue
    private let secret: Data
    private let timeout: TimeInterval
    private let directTimeout: TimeInterval
    private let maxConcurrent: Int
    private let onProgress: @Sendable (Progress) -> Void
    private let completion: @Sendable (AuthenticatedPeer?) -> Void
    private var attempts: [UUID: Attempt] = [:]
    private var generation: UInt64 = 0
    private var stopped = true
    private var searching = false
    private var candidates: [PeerEndpoint] = []
    private var nextCandidate = 0
    private var makeCandidates: (@Sendable () -> [PeerEndpoint])?

    public init(queue: DispatchQueue, secret: Data, timeout: TimeInterval = 2, directTimeout: TimeInterval = 7,
                maxConcurrent: Int = 4,
                onProgress: @escaping @Sendable (Progress) -> Void = { _ in },
                completion: @escaping @Sendable (AuthenticatedPeer?) -> Void) {
        self.queue = queue; self.secret = secret
        self.timeout = max(0.1, min(5, timeout))
        self.directTimeout = max(0.1, min(7, directTimeout))
        self.maxConcurrent = max(1, min(4, maxConcurrent))
        self.onProgress = onProgress; self.completion = completion
    }

    public func start(previous: PeerEndpoint, candidates: @escaping @Sendable () -> [PeerEndpoint]) {
        dispatchPrecondition(condition: .onQueue(queue))
        cancel()
        stopped = false; searching = false; nextCandidate = 0
        makeCandidates = candidates
        onProgress(.connecting(previous.host))
        launch(previous, epoch: generation)
    }

    public func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        stopped = true; generation &+= 1
        for attempt in attempts.values {
            attempt.timer?.cancel()
            attempt.socket.stateUpdateHandler = nil
            attempt.socket.cancel()
        }
        attempts.removeAll(); candidates.removeAll(); makeCandidates = nil
    }

    private func launch(_ endpoint: PeerEndpoint, epoch: UInt64) {
        guard !stopped, epoch == generation, let port = NWEndpoint.Port(rawValue: endpoint.port) else { return }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // Discovered hosts are bound to the attached Wi-Fi/Ethernet interface;
        // they cannot silently follow a VPN or a newly selected default route.
        parameters.requiredInterface = endpoint.interface
        let socket = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
        let attempt = Attempt(endpoint: endpoint, socket: socket), id = UUID()
        attempts[id] = attempt
        let timer = DispatchWorkItem { [weak self] in self?.failed(id, epoch: epoch) }
        attempt.timer = timer
        queue.asyncAfter(deadline: .now() + (searching ? timeout : directTimeout), execute: timer)
        socket.stateUpdateHandler = { [weak self] state in
            guard let self, self.isCurrent(id, epoch: epoch), let attempt = self.attempts[id] else { return }
            switch state {
            case .ready:
                do {
                    let hello = try CrossMouseWire.clientHello(secret: self.secret, clientNonce: attempt.nonce)
                    socket.send(content: hello, completion: .contentProcessed { [weak self] error in
                        if error != nil { self?.failed(id, epoch: epoch) }
                    })
                    self.receive(id, epoch: epoch)
                } catch { self.failed(id, epoch: epoch) }
            case .failed, .waiting, .cancelled: self.failed(id, epoch: epoch)
            default: break
            }
        }
        socket.start(queue: queue)
    }

    private func isCurrent(_ id: UUID, epoch: UInt64) -> Bool {
        !stopped && epoch == generation && attempts[id] != nil
    }

    private func receive(_ id: UUID, epoch: UInt64) {
        guard isCurrent(id, epoch: epoch), let attempt = attempts[id] else { return }
        attempt.socket.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, complete, error in
            guard let self, self.isCurrent(id, epoch: epoch), let attempt = self.attempts[id] else { return }
            do {
                if let data { try attempt.buffer.append(data) }
                if attempt.key == nil, let hello = attempt.buffer.take(CrossMouseWire.helloLength) {
                    let serverNonce = try CrossMouseWire.verifyServerHello(hello, secret: self.secret,
                                                                          clientNonce: attempt.nonce)
                    let key = try CrossMouseWire.sessionKey(secret: self.secret,
                        clientNonce: attempt.nonce, serverNonce: serverNonce)
                    attempt.key = key
                    let ping = try CrossMouseWire.frame(CrossMouseMessage(type: "ping"), sessionKey: key,
                                                        sequence: 0, direction: .macToWindows)
                    attempt.socket.send(content: ping, completion: .contentProcessed { [weak self] error in
                        if error != nil { self?.failed(id, epoch: epoch) }
                    })
                }
                if let key = attempt.key, let frame = try attempt.buffer.takeEncryptedFrame() {
                    let pong = try CrossMouseWire.open(frame, sessionKey: key, sequence: 0, direction: .windowsToMac)
                    guard pong.type == "pong", error == nil, !complete else { throw CrossMouseError.invalidHandshake }
                    self.succeeded(id, epoch: epoch, pong: pong)
                    return
                }
            } catch {
                // Intentionally do not echo a peer-supplied body or key into a log.
                self.failed(id, epoch: epoch); return
            }
            if complete || error != nil { self.failed(id, epoch: epoch) }
            else { self.receive(id, epoch: epoch) }
        }
    }

    private func succeeded(_ id: UUID, epoch: UInt64, pong: CrossMouseMessage) {
        guard isCurrent(id, epoch: epoch), let winner = attempts.removeValue(forKey: id),
              let key = winner.key else { return }
        winner.timer?.cancel(); winner.socket.stateUpdateHandler = nil
        // Remove the winner before cancellation; preserve this authenticated
        // socket rather than probing and making a second competing connection.
        cancel()
        completion(AuthenticatedPeer(endpoint: winner.endpoint, connection: winner.socket,
            sessionKey: key, firstPong: pong, remainingBytes: winner.buffer))
    }

    private func failed(_ id: UUID, epoch: UInt64) {
        guard isCurrent(id, epoch: epoch), let attempt = attempts.removeValue(forKey: id) else { return }
        attempt.timer?.cancel(); attempt.socket.stateUpdateHandler = nil; attempt.socket.cancel()
        if !searching {
            searching = true
            var seen = Set<String>()
            let proposed = makeCandidates?() ?? []
            candidates = proposed.prefix(254).filter {
                ($0.host != attempt.endpoint.host || $0.port != attempt.endpoint.port)
                    && seen.insert("\($0.host):\($0.port)").inserted
            }
            makeCandidates = nil
            if !candidates.isEmpty { onProgress(.searching(candidates.count)) }
        }
        pump(epoch: epoch)
    }

    private func pump(epoch: UInt64) {
        guard !stopped, epoch == generation else { return }
        while attempts.count < maxConcurrent && nextCandidate < candidates.count {
            let endpoint = candidates[nextCandidate]; nextCandidate += 1
            launch(endpoint, epoch: epoch)
        }
        if attempts.isEmpty && nextCandidate == candidates.count {
            cancel(); onProgress(.exhausted); completion(nil)
        }
    }
}

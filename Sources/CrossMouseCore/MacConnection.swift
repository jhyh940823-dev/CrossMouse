import CryptoKit
import Foundation
import Network

public struct PeerRecoveryTiming: Sendable {
    let directTimeout: TimeInterval
    let candidateTimeout: TimeInterval
    let retryDelay: TimeInterval
    let discoveryCooldown: TimeInterval
    let silenceLimit: TimeInterval
    public static let standard = PeerRecoveryTiming(directTimeout: 7, candidateTimeout: 2,
        retryDelay: 2, discoveryCooldown: 30, silenceLimit: 7)
}

/// All connection state and cryptographic counters live on one serial queue.
/// In particular, an event-tap callback never waits for the network.
public final class MacConnection: @unchecked Sendable {
    private var host: String
    private let port: UInt16
    private let secret: Data
    private let onConnected: @Sendable (Bool) -> Void
    private let onMessage: @Sendable (CrossMouseMessage) -> Void
    private let onStatus: @Sendable (String) -> Void
    private let saveHost: @Sendable (String) throws -> Void
    private let candidateProvider: (@Sendable () -> [PeerEndpoint])?
    private let timing: PeerRecoveryTiming
    private let queue = DispatchQueue(label: "CrossMouse.connection", qos: .userInteractive)
    private var connection: NWConnection?
    private var buffer = FramedByteBuffer()
    private var sessionKey: Data?
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0
    private var stopped = true
    private var dialer: PairedPeerDialer?
    private var retry: DispatchWorkItem?
    private var recoveryEpoch: UInt64 = 0
    private var lastDiscoveryEnded: TimeInterval?
    private var discoveryAttempted = false
    private var pathMonitor: NWPathMonitor?
    private var healthTimer: DispatchSourceTimer?
    private var lastResponse: TimeInterval?
    private var hostNeedsSave = false
    private var moveTimer: DispatchSourceTimer?
    private var pendingMoveX = 0
    private var pendingMoveY = 0
    private var pendingTransferId: String?
    private var clipboardUpload: String?

    public init(
        host: String,
        port: UInt16,
        secret: Data,
        onConnected: @escaping @Sendable (Bool) -> Void,
        onMessage: @escaping @Sendable (CrossMouseMessage) -> Void,
        onStatus: @escaping @Sendable (String) -> Void = { _ in },
        saveHost: @escaping @Sendable (String) throws -> Void = { _ in },
        candidateProvider: (@Sendable () -> [PeerEndpoint])? = nil,
        timing: PeerRecoveryTiming = .standard
    ) {
        self.host = host
        self.port = port
        self.secret = secret
        self.onConnected = onConnected
        self.onMessage = onMessage
        self.onStatus = onStatus; self.saveHost = saveHost
        self.candidateProvider = candidateProvider; self.timing = timing
    }

    public func start() {
        queue.async { [self] in
            guard stopped else { return }
            self.stopped = false
            let monitor = NWPathMonitor()
            pathMonitor = monitor
            monitor.pathUpdateHandler = { [weak self, weak monitor] path in
                guard let self, let monitor, self.pathMonitor === monitor, !self.stopped else { return }
                if path.status != .satisfied {
                    self.disconnect()
                    self.onStatus("네트워크 연결 없음 · 연결되면 페어링된 PC를 다시 찾습니다.")
                } else if self.connection == nil && self.dialer == nil {
                    self.retry?.cancel(); self.retry = nil
                    self.connect()
                }
            }
            monitor.start(queue: queue)
            let health = DispatchSource.makeTimerSource(queue: queue)
            health.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
            health.setEventHandler { [weak self] in
                guard let self, let last = self.lastResponse, self.sessionKey != nil,
                      ProcessInfo.processInfo.systemUptime - last > self.timing.silenceLimit else { return }
                self.disconnect()
            }
            healthTimer = health; health.resume()
            if self.moveTimer == nil {
                // Send at most one relative mouse movement per 8ms (~125 Hz).
                // Coalesce high-Hz mouse events instead of letting hundreds of
                // tiny encrypted TCP writes form a lagging input backlog.
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + .milliseconds(8),
                               repeating: .milliseconds(8), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.flushMotion() }
                self.moveTimer = timer
                timer.resume()
            }
            self.connect()
        }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.pathMonitor?.cancel(); self.pathMonitor = nil
            self.healthTimer?.cancel(); self.healthTimer = nil
            self.moveTimer?.cancel()
            self.moveTimer = nil
            self.disconnect()
        }
    }

    public func send(_ message: CrossMouseMessage) {
        queue.async { [self] in
            guard !self.stopped else { return }
            guard self.sessionKey != nil else { return }
            if message.type == "leave" || message.type == "prepare" { self.clipboardUpload = nil }
            if message.type == "move" {
                if self.pendingTransferId != message.transferId { self.flushMotion() }
                self.pendingTransferId = message.transferId
                self.pendingMoveX = max(-32768, min(32768, self.pendingMoveX + (message.dx ?? 0)))
                self.pendingMoveY = max(-32768, min(32768, self.pendingMoveY + (message.dy ?? 0)))
            } else {
                // Preserve move-before-click and move-before-leave ordering.
                self.flushMotion()
                self.sendFrame(message)
            }
        }
    }

    /// Bounded, completion-paced upload. Input/heartbeat frames may interleave,
    /// and cancelling/reconnecting drops the remaining old clipboard frames.
    public func sendClipboard(_ frames: [CrossMouseMessage], id: String) {
        queue.async { [self] in
            guard !stopped, let socket = connection, sessionKey != nil else { return }
            clipboardUpload = id
            flushMotion()
            sendClipboardFrame(frames, index: 0, id: id, socket: socket)
        }
    }

    public func cancelClipboard(_ id: String) {
        queue.async { [self] in
            if clipboardUpload == id { clipboardUpload = nil }
        }
    }

    private func sendClipboardFrame(_ frames: [CrossMouseMessage], index: Int, id: String, socket: NWConnection) {
        guard !stopped, connection === socket, clipboardUpload == id, let key = sessionKey else { return }
        guard index < frames.count else { clipboardUpload = nil; return }
        do {
            let frame = try CrossMouseWire.frame(frames[index], sessionKey: key,
                sequence: sendSequence, direction: .macToWindows)
            sendSequence += 1
            socket.send(content: frame, completion: .contentProcessed { [weak self, weak socket] error in
                guard let self, let socket else { return }
                if error != nil { self.disconnect(ifCurrent: socket); return }
                self.sendClipboardFrame(frames, index: index + 1, id: id, socket: socket)
            })
        } catch { clipboardUpload = nil } // No content-bearing encoding errors in logs.
    }

    private func flushMotion() {
        guard pendingMoveX != 0 || pendingMoveY != 0 else { return }
        let dx = pendingMoveX
        let dy = pendingMoveY
        let id = pendingTransferId
        pendingMoveX = 0
        pendingMoveY = 0
        pendingTransferId = nil
        sendFrame(CrossMouseMessage(type: "move", dx: dx, dy: dy, transferId: id,
            motionTimeUs: Int64(DispatchTime.now().uptimeNanoseconds / 1_000)))
    }

    private func sendFrame(_ message: CrossMouseMessage) {
        guard !stopped, let connection, let key = sessionKey else { return }
        do {
            let frame = try CrossMouseWire.frame(
                message, sessionKey: key, sequence: sendSequence,
                direction: .macToWindows
            )
            sendSequence += 1
            connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
                if error != nil, let connection { self?.disconnect(ifCurrent: connection) }
            })
        } catch {
            NSLog("CrossMouse: unable to encode event: %@", String(describing: error))
        }
    }

    private func connect() {
        guard !stopped, connection == nil, dialer == nil, port > 0 else { return }
        retry?.cancel(); retry = nil
        recoveryEpoch &+= 1
        let epoch = recoveryEpoch
        discoveryAttempted = false
        let next = PairedPeerDialer(queue: queue, secret: secret,
            timeout: timing.candidateTimeout, directTimeout: timing.directTimeout,
            onProgress: { [weak self] progress in
                guard let self, !self.stopped, self.recoveryEpoch == epoch else { return }
                switch progress {
                case .connecting(let address): self.onStatus("\(address) · 저장된 Windows 주소에 연결 중…")
                case .searching:
                    self.onStatus("기존 주소 연결 실패 · 같은 네트워크에서 페어링된 PC 자동 검색 중…")
                case .exhausted:
                    self.onStatus("Windows 응답 없음 · 주소 자동 검색/재연결을 대기 중입니다.")
                }
            }, completion: { [weak self] peer in
                guard let self, !self.stopped, self.recoveryEpoch == epoch else {
                    peer?.connection.cancel(); return
                }
                self.dialer = nil
                if self.discoveryAttempted { self.lastDiscoveryEnded = ProcessInfo.processInfo.systemUptime }
                if let peer { self.adopt(peer) }
                else { self.scheduleRetry() }
            })
        dialer = next
        next.start(previous: PeerEndpoint(host: host, port: port), candidates: { [weak self] in
            guard let self, !self.stopped, self.recoveryEpoch == epoch else { return [] }
            let now = ProcessInfo.processInfo.systemUptime
            if let ended = self.lastDiscoveryEnded, now - ended < self.timing.discoveryCooldown { return [] }
            self.discoveryAttempted = true
            return self.candidateProvider?() ?? LANPeerCandidates.snapshot(previous: self.host,
                port: self.port, path: self.pathMonitor?.currentPath)
        })
    }

    private func adopt(_ peer: AuthenticatedPeer) {
        let socket = peer.connection
        connection = socket; sessionKey = peer.sessionKey
        buffer = peer.remainingBytes
        sendSequence = peer.sendSequence; receiveSequence = peer.receiveSequence
        lastResponse = ProcessInfo.processInfo.systemUptime
        pendingMoveX = 0; pendingMoveY = 0; pendingTransferId = nil; clipboardUpload = nil
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            guard let self, let socket, self.connection === socket else { return }
            switch state {
            case .failed, .waiting, .cancelled: self.disconnect(ifCurrent: socket)
            default: break
            }
        }
        // The discovered candidate has already verified the original pairing
        // key AND encrypted receiver response. Only now may it replace a hint.
        let changed = host != peer.endpoint.host
        host = peer.endpoint.host
        hostNeedsSave = hostNeedsSave || changed
        var saved = true
        if hostNeedsSave {
            do { try saveHost(host); hostNeedsSave = false } catch { saved = false }
        }
        onConnected(true)
        onMessage(peer.firstPong)
        onStatus(saved ? "\(host) · " + (changed ? "페어링된 PC를 자동으로 다시 찾았습니다." : "페어링 인증 연결됨")
                       : "\(host) · 연결됨 · 새 주소 저장 실패")
        do { try processBuffer() }
        catch { disconnect(ifCurrent: socket); return }
        receive(socket)
    }

    private func scheduleRetry() {
        guard !stopped else { return }
        retry?.cancel()
        let epoch = recoveryEpoch
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.recoveryEpoch == epoch else { return }
            self.retry = nil; self.connect()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + timing.retryDelay, execute: work)
    }

    private func receive(_ socket: NWConnection) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak socket] data, _, complete, error in
            guard let self, let socket, self.connection === socket else { return }
            do {
                if let data { try self.buffer.append(data) }
                try self.processBuffer()
            } catch {
                NSLog("CrossMouse: rejected connection: %@", String(describing: error))
                self.disconnect(ifCurrent: socket)
                return
            }
            if complete || error != nil {
                self.disconnect(ifCurrent: socket)
            } else {
                self.receive(socket)
            }
        }
    }

    private func processBuffer() throws {
        while let ciphertext = try buffer.takeEncryptedFrame() {
            guard let key = sessionKey else { throw CrossMouseError.invalidHandshake }
            let message = try CrossMouseWire.open(
                ciphertext, sessionKey: key,
                sequence: receiveSequence, direction: .windowsToMac
            )
            receiveSequence += 1
            lastResponse = ProcessInfo.processInfo.systemUptime
            onMessage(message)
        }
    }

    private func disconnect(ifCurrent socket: NWConnection? = nil) {
        if let socket, connection !== socket { return }
        let wasConnected = sessionKey != nil
        recoveryEpoch &+= 1
        retry?.cancel(); retry = nil
        dialer?.cancel(); dialer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        sessionKey = nil
        buffer = FramedByteBuffer()
        pendingMoveX = 0
        pendingMoveY = 0
        pendingTransferId = nil
        clipboardUpload = nil
        lastResponse = nil
        if wasConnected { onConnected(false) }
        scheduleRetry()
    }
}

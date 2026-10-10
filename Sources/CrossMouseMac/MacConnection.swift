import CrossMouseCore
import CryptoKit
import Foundation
import Network

/// All connection state and cryptographic counters live on one serial queue.
/// In particular, an event-tap callback never waits for the network.
final class MacConnection: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let secret: Data
    private let onConnected: @Sendable (Bool) -> Void
    private let onMessage: @Sendable (CrossMouseMessage) -> Void
    private let queue = DispatchQueue(label: "CrossMouse.connection")
    private var connection: NWConnection?
    private var buffer = FramedByteBuffer()
    private var clientNonce = Data()
    private var sessionKey: Data?
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0
    private var stopped = false
    private var moveTimer: DispatchSourceTimer?
    private var pendingMoveX = 0
    private var pendingMoveY = 0

    init(
        host: String,
        port: UInt16,
        secret: Data,
        onConnected: @escaping @Sendable (Bool) -> Void,
        onMessage: @escaping @Sendable (CrossMouseMessage) -> Void
    ) {
        self.host = host
        self.port = port
        self.secret = secret
        self.onConnected = onConnected
        self.onMessage = onMessage
    }

    func start() {
        queue.async { [self] in
            self.stopped = false
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

    func stop() {
        queue.async {
            self.stopped = true
            self.moveTimer?.cancel()
            self.moveTimer = nil
            self.disconnect()
        }
    }

    func send(_ message: CrossMouseMessage) {
        queue.async { [self] in
            guard self.sessionKey != nil else { return }
            if message.type == "move" {
                self.pendingMoveX = max(-32768, min(32768, self.pendingMoveX + (message.dx ?? 0)))
                self.pendingMoveY = max(-32768, min(32768, self.pendingMoveY + (message.dy ?? 0)))
            } else {
                // Preserve move-before-click and move-before-leave ordering.
                self.flushMotion()
                self.sendFrame(message)
            }
        }
    }

    private func flushMotion() {
        guard pendingMoveX != 0 || pendingMoveY != 0 else { return }
        let dx = pendingMoveX
        let dy = pendingMoveY
        pendingMoveX = 0
        pendingMoveY = 0
        sendFrame(CrossMouseMessage(type: "move", dx: dx, dy: dy))
    }

    private func sendFrame(_ message: CrossMouseMessage) {
        guard let connection, let key = sessionKey else { return }
        do {
            let frame = try CrossMouseWire.frame(
                message, sessionKey: key, sequence: sendSequence,
                direction: .macToWindows
            )
            sendSequence += 1
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.disconnect() }
            })
        } catch {
            NSLog("CrossMouse: unable to encode event: %@", String(describing: error))
        }
    }

    private func connect() {
        guard !stopped, connection == nil, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return
        }
        buffer = FramedByteBuffer()
        clientNonce = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        sessionKey = nil
        sendSequence = 0
        receiveSequence = 0
        pendingMoveX = 0
        pendingMoveY = 0
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let socket = NWConnection(
            host: NWEndpoint.Host(host), port: endpointPort,
            using: NWParameters(tls: nil, tcp: tcp)
        )
        connection = socket
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            guard let self, let socket, self.connection === socket else { return }
            switch state {
            case .ready:
                do {
                    let hello = try CrossMouseWire.clientHello(
                        secret: self.secret, clientNonce: self.clientNonce
                    )
                    socket.send(content: hello, completion: .contentProcessed { [weak self] error in
                        if error != nil { self?.disconnect() }
                    })
                    self.receive(socket)
                } catch {
                    self.disconnect()
                }
            case .failed(_), .cancelled:
                self.disconnect()
            default:
                break
            }
        }
        socket.start(queue: queue)
    }

    private func receive(_ socket: NWConnection) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak socket] data, _, complete, error in
            guard let self, let socket, self.connection === socket else { return }
            do {
                if let data { try self.buffer.append(data) }
                try self.processBuffer()
            } catch {
                NSLog("CrossMouse: rejected connection: %@", String(describing: error))
                self.disconnect()
                return
            }
            if complete || error != nil {
                self.disconnect()
            } else {
                self.receive(socket)
            }
        }
    }

    private func processBuffer() throws {
        if sessionKey == nil {
            guard let hello = buffer.take(CrossMouseWire.helloLength) else { return }
            let serverNonce = try CrossMouseWire.verifyServerHello(
                hello, secret: secret, clientNonce: clientNonce
            )
            sessionKey = try CrossMouseWire.sessionKey(
                secret: secret, clientNonce: clientNonce, serverNonce: serverNonce
            )
            onConnected(true)
        }

        while let ciphertext = try buffer.takeEncryptedFrame() {
            guard let key = sessionKey else { throw CrossMouseError.invalidHandshake }
            let message = try CrossMouseWire.open(
                ciphertext, sessionKey: key,
                sequence: receiveSequence, direction: .windowsToMac
            )
            receiveSequence += 1
            onMessage(message)
        }
    }

    private func disconnect() {
        let wasConnected = sessionKey != nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        sessionKey = nil
        buffer = FramedByteBuffer()
        pendingMoveX = 0
        pendingMoveY = 0
        if wasConnected { onConnected(false) }
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.connect()
        }
    }
}

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
        queue.async { self.connect() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.disconnect()
        }
    }

    func send(_ message: CrossMouseMessage) {
        queue.async { [self] in
            guard let connection = self.connection, let key = self.sessionKey else { return }
            do {
                let frame = try CrossMouseWire.frame(
                    message, sessionKey: key, sequence: self.sendSequence,
                    direction: .macToWindows
                )
                self.sendSequence += 1
                connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.disconnect() }
                })
            } catch {
                NSLog("CrossMouse: unable to encode event: %@", String(describing: error))
            }
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
        let socket = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
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
        if wasConnected { onConnected(false) }
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.connect()
        }
    }
}

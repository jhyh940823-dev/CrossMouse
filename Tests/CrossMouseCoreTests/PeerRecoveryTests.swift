import CryptoKit
import Foundation
import Network
import XCTest
@testable import CrossMouseCore

final class PeerRecoveryTests: XCTestCase, @unchecked Sendable {
    private let key = Data(repeating: 0x37, count: 32)

    func testScopeIsActualSmallPrivateSubnetAndPrefersNearbyDHCPAddresses() {
        let list = LocalPeerSubnet.candidates(previous: "192.168.219.104", local: "192.168.219.106",
            netmask: "255.255.255.0", excluding: ["192.168.219.1"])
        XCTAssertEqual(list.count, 251)
        XCTAssertEqual(list.prefix(7), ["192.168.219.103", "192.168.219.105", "192.168.219.102",
            "192.168.219.101", "192.168.219.107", "192.168.219.100", "192.168.219.108"])
        for excluded in ["192.168.219.0", "192.168.219.1", "192.168.219.104", "192.168.219.106", "192.168.219.255"] {
            XCTAssertFalse(list.contains(excluded))
        }
        XCTAssertTrue(list.allSatisfy { $0.hasPrefix("192.168.219.") })
        for (host, local, mask) in [
            ("8.8.8.8", "8.8.8.7", "255.255.255.0"),
            ("192.168.219.104", "192.168.1.4", "255.255.255.0"),
            ("192.168.219.104", "192.168.219.106", "255.255.0.0"),
            ("192.168.219.104", "192.168.219.106", "255.255.255.253"),
            ("192.168.219.0", "192.168.219.106", "255.255.255.0"),
            ("169.254.1.2", "169.254.1.3", "255.255.255.0"),
            ("::1", "127.0.0.1", "255.255.255.0"),
            ("192.168.219.010", "192.168.219.106", "255.255.255.0")
        ] {
            XCTAssertTrue(LocalPeerSubnet.candidates(previous: host, local: local, netmask: mask).isEmpty)
        }
        XCTAssertEqual(LocalPeerSubnet.candidates(previous: "172.16.5.5", local: "172.16.5.6",
                                                   netmask: "255.255.255.252"), [])
    }

    func testAddressStoreSupportsRepeatedChangesAndPreservesManualEdits() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("host")
        try "192.168.219.104\n".write(to: file, atomically: true, encoding: .utf8)
        let store = PeerAddressStore(url: file, expectedHost: "192.168.219.104")
        try store.saveVerifiedHost("192.168.219.108")
        try store.saveVerifiedHost("192.168.219.109")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "192.168.219.109\n")
        try "192.168.219.120\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.saveVerifiedHost("192.168.219.111"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "192.168.219.120\n")
    }

    func testDirectAuthenticatedConnectionDoesNotSearchAndContinuesCipherCounters() async throws {
        let receiver = try LoopbackPeer(key: key)
        defer { receiver.stop() }
        let ready = expectation(description: "authenticated direct connection")
        let pongs = expectation(description: "initial plus ordinary pong"); pongs.expectedFulfillmentCount = 2
        let counters = LockedCounters()
        let client = MacConnection(host: "127.0.0.1", port: receiver.port, secret: key,
            onConnected: { if $0 { ready.fulfill() } },
            onMessage: { if $0.type == "pong" { pongs.fulfill() } },
            saveHost: { _ in counters.save() }, candidateProvider: { counters.scan(); return [] }, timing: .fastTest)
        client.start()
        defer { client.stop() }
        await fulfillment(of: [ready], timeout: 3)
        // The establishment deadline has passed. It must not cancel a socket
        // whose ownership has already transferred to the ordinary transport.
        try await Task.sleep(nanoseconds: 250_000_000)
        client.send(CrossMouseMessage(type: "ping"))
        await fulfillment(of: [pongs], timeout: 3)
        XCTAssertEqual(counters.values.scans, 0)
        XCTAssertEqual(counters.values.saves, 0)
        XCTAssertEqual(receiver.types, ["ping", "ping"])
    }

    func testWrongKeyStalledAndUnreadyHostsCannotReplaceAddress() async throws {
        let wrong = try LoopbackPeer(key: Data(repeating: 0x91, count: 32), mode: .wrongKey)
        let silent = try LoopbackPeer(key: key, mode: .silent)
        let noPong = try LoopbackPeer(key: key, mode: .noPong)
        let correct = try LoopbackPeer(key: key, mode: .fragmented)
        defer { wrong.stop(); silent.stop(); noPong.stop(); correct.stop() }
        let ready = expectation(description: "correct peer only")
        let counters = LockedCounters()
        let client = MacConnection(host: "127.0.0.2", port: correct.port, secret: key,
            onConnected: { if $0 { ready.fulfill() } }, onMessage: { _ in },
            saveHost: { host in counters.save(host) },
            candidateProvider: { counters.scan(); return [wrong.endpoint, silent.endpoint, noPong.endpoint, correct.endpoint] },
            timing: .fastTest)
        client.start(); defer { client.stop() }
        await fulfillment(of: [ready], timeout: 4)
        XCTAssertEqual(counters.values.hosts, ["127.0.0.1"])
        XCTAssertEqual(counters.values.scans, 1)
        XCTAssertEqual(correct.types, ["ping"])
    }

    func testCancelDuringHandshakeNeverAdoptsLateSuccess() async throws {
        let delayed = try LoopbackPeer(key: key, mode: .delayed)
        defer { delayed.stop() }
        let callback = expectation(description: "no post-stop completion"); callback.isInverted = true
        let queue = DispatchQueue(label: "CrossMouse.test.cancellation")
        let dialer = PairedPeerDialer(queue: queue, secret: key, timeout: 1, directTimeout: 1,
            completion: { peer in peer?.connection.cancel(); callback.fulfill() })
        queue.async {
            dialer.start(previous: delayed.endpoint, candidates: { [] })
            queue.asyncAfter(deadline: .now() + 0.05) { dialer.cancel() }
        }
        await fulfillment(of: [callback], timeout: 0.6)
    }

    func testValidHelloWithoutEncryptedPongIsNeverAdopted() async throws {
        let peer = try LoopbackPeer(key: key, mode: .noPong)
        defer { peer.stop() }
        let finished = expectation(description: "not a live receiver")
        let queue = DispatchQueue(label: "CrossMouse.test.no-pong")
        let dialer = PairedPeerDialer(queue: queue, secret: key, timeout: 0.15, directTimeout: 0.15,
            completion: { connected in
                XCTAssertNil(connected)
                connected?.connection.cancel()
                finished.fulfill()
            })
        queue.async { dialer.start(previous: peer.endpoint, candidates: { [] }) }
        await fulfillment(of: [finished], timeout: 2)
    }

    func testStopThenRestartIgnoresOldHandshakeAndRetryCallbacks() async throws {
        let receiver = try LoopbackPeer(key: key, mode: .delayed)
        defer { receiver.stop() }
        let connected = expectation(description: "only the restarted lifetime connects")
        connected.assertForOverFulfill = true
        let client = MacConnection(host: "127.0.0.1", port: receiver.port, secret: key,
            onConnected: { if $0 { connected.fulfill() } }, onMessage: { _ in },
            candidateProvider: { [] })
        client.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        client.stop(); client.start()
        defer { client.stop() }
        await fulfillment(of: [connected], timeout: 3)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(receiver.types, ["ping"])
    }

    func testDiscoveryHasCooldownWhenPCIsAbsent() async throws {
        let silent = try LoopbackPeer(key: key, mode: .silent)
        defer { silent.stop() }
        let counters = LockedCounters()
        let forbidden = expectation(description: "silent TCP is not connected"); forbidden.isInverted = true
        let client = MacConnection(host: "127.0.0.2", port: silent.port, secret: key,
            onConnected: { if $0 { forbidden.fulfill() } }, onMessage: { _ in },
            saveHost: { host in counters.save(host) },
            candidateProvider: { counters.scan(); return [silent.endpoint] },
            timing: PeerRecoveryTiming(directTimeout: 0.1, candidateTimeout: 0.1,
                retryDelay: 0.05, discoveryCooldown: 10, silenceLimit: 7))
        client.start()
        await fulfillment(of: [forbidden], timeout: 0.8)
        client.stop()
        XCTAssertEqual(counters.values.scans, 1)
        XCTAssertEqual(counters.values.saves, 0)
    }

    func testWorkingSocketDropAutomaticallyReauthenticatesWithoutMovingCursor() async throws {
        let receiver = try LoopbackPeer(key: key)
        defer { receiver.stop() }
        let first = expectation(description: "first connection")
        let again = expectation(description: "reconnected")
        let counters = LockedCounters()
        let client = MacConnection(host: "127.0.0.1", port: receiver.port, secret: key,
            onConnected: { connected in
                guard connected else { return }
                if counters.connect() == 1 { first.fulfill() } else { again.fulfill() }
            }, onMessage: { _ in }, candidateProvider: { counters.scan(); return [] }, timing: .fastTest)
        client.start(); defer { client.stop() }
        await fulfillment(of: [first], timeout: 3)
        receiver.dropConnections()
        await fulfillment(of: [again], timeout: 3)
        XCTAssertEqual(counters.values.scans, 0)
        XCTAssertEqual(receiver.types, ["ping", "ping"])
    }
}

private extension PeerRecoveryTiming {
    static let fastTest = PeerRecoveryTiming(directTimeout: 0.15, candidateTimeout: 0.3,
        retryDelay: 0.1, discoveryCooldown: 2, silenceLimit: 7)
}

private final class LockedCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var scans = 0, saves = 0, connections = 0
    private var hosts: [String] = []
    func scan() { lock.lock(); scans += 1; lock.unlock() }
    func save(_ host: String = "") { lock.lock(); saves += 1; hosts.append(host); lock.unlock() }
    func connect() -> Int { lock.lock(); defer { lock.unlock() }; connections += 1; return connections }
    var values: (scans: Int, saves: Int, hosts: [String]) {
        lock.lock(); defer { lock.unlock() }; return (scans, saves, hosts)
    }
}

/// Owned loopback-only protocol fixture. No input injection, real pairing file,
/// system clipboard, NIC change, LAN scanning or user credentials are involved.
private final class LoopbackPeer: @unchecked Sendable {
    enum Mode: Sendable { case normal, wrongKey, silent, noPong, fragmented, delayed }
    private final class Client: @unchecked Sendable {
        let socket: NWConnection
        var buffer = FramedByteBuffer(), sessionKey: Data?
        var sent: UInt64 = 0, received: UInt64 = 0
        init(_ socket: NWConnection) { self.socket = socket }
    }
    private let queue = DispatchQueue(label: "CrossMouse.test.receiver")
    private let listener: NWListener
    private let key: Data, mode: Mode
    private var clients: [Client] = []
    private var receivedTypes: [String] = []
    let port: UInt16
    var endpoint: PeerEndpoint { PeerEndpoint(host: "127.0.0.1", port: port) }
    var types: [String] { queue.sync { receivedTypes } }

    init(key: Data, mode: Mode = .normal) throws {
        self.key = key; self.mode = mode
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { socket in socket.cancel() }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let bound = listener.port else {
            listener.cancel(); throw CocoaError(.fileReadUnknown)
        }
        port = bound.rawValue
        listener.newConnectionHandler = { [weak self] socket in
            guard let self else { socket.cancel(); return }
            let client = Client(socket); self.clients.append(client)
            socket.start(queue: self.queue)
            if self.mode != .silent { self.receive(client) }
        }
    }

    func dropConnections() { queue.async { self.clients.forEach { $0.socket.cancel() }; self.clients.removeAll() } }
    func stop() { queue.async { self.listener.cancel(); self.clients.forEach { $0.socket.cancel() }; self.clients.removeAll() } }

    private func receive(_ client: Client) {
        client.socket.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            do {
                if let data { try client.buffer.append(data) }
                if client.sessionKey == nil, let hello = client.buffer.take(52) {
                    let nonce = Data(hello[4..<20])
                    if self.mode != .wrongKey {
                        guard try CrossMouseWire.clientHello(secret: self.key, clientNonce: nonce) == hello else {
                            throw CrossMouseError.unauthenticated
                        }
                    }
                    let serverNonce = Data(repeating: 0x12, count: 16)
                    let response = try CrossMouseWire.serverHello(secret: self.key,
                        clientNonce: nonce, serverNonce: serverNonce)
                    client.sessionKey = try CrossMouseWire.sessionKey(secret: self.key,
                        clientNonce: nonce, serverNonce: serverNonce)
                    if self.mode == .fragmented {
                        client.socket.send(content: Data(response.prefix(7)), completion: .contentProcessed { _ in })
                        self.queue.asyncAfter(deadline: .now() + 0.02) {
                            client.socket.send(content: Data(response.dropFirst(7)), completion: .contentProcessed { _ in })
                        }
                    } else if self.mode == .delayed {
                        self.queue.asyncAfter(deadline: .now() + 0.2) {
                            client.socket.send(content: response, completion: .contentProcessed { _ in })
                        }
                    } else { client.socket.send(content: response, completion: .contentProcessed { _ in }) }
                }
                while let key = client.sessionKey, let frame = try client.buffer.takeEncryptedFrame() {
                    let message = try CrossMouseWire.open(frame, sessionKey: key,
                        sequence: client.received, direction: .macToWindows)
                    client.received += 1; self.receivedTypes.append(message.type)
                    if message.type == "ping", self.mode != .noPong {
                        let pong = try CrossMouseWire.frame(CrossMouseMessage(type: "pong", capability: "handoff-2"),
                            sessionKey: key, sequence: client.sent, direction: .windowsToMac)
                        client.sent += 1
                        client.socket.send(content: pong, completion: .contentProcessed { _ in })
                    }
                }
            } catch { client.socket.cancel(); return }
            if complete || error != nil { client.socket.cancel() }
            else { self.receive(client) }
        }
    }
}

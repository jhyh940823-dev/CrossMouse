import Foundation
import XCTest
@testable import CrossMouseCore

final class TextClipboardReadProcessTests: XCTestCase {
    /// The fixture is a single Python process, not a shell with surviving sleep
    /// children. It never imports AppKit or accesses any user's pasteboard.
    private final class Fixture {
        let directory: URL
        let executable: URL
        init(_ body: String) throws {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
                throw XCTSkip("System Python is unavailable for isolated process fixtures")
            }
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CrossMouse-read-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            executable = directory.appendingPathComponent("reader")
            try ("#!/usr/bin/python3\nimport sys, time, json, base64, signal\n" + body)
                .write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    private final class Reply {
        var continuation: CheckedContinuation<TextClipboardReadProcess.Outcome, Never>?
        var count = 0
        var pulse = false
        func complete(_ result: TextClipboardReadProcess.Outcome) {
            let pending = continuation; continuation = nil
            pending?.resume(returning: result)
        }
    }

    @MainActor
    private func outcomeName(_ outcome: TextClipboardReadProcess.Outcome) -> String {
        switch outcome {
        case .read: "read"
        case .failed: "failed"
        case .timedOut: "timedOut"
        case .busy: "busy"
        }
    }

    @MainActor
    private func read(_ reader: TextClipboardReadProcess, acknowledged: Int? = nil,
                      name: String = "CrossMouse-test-no-board-access") async -> TextClipboardReadProcess.Outcome {
        let reply = Reply()
        return await withCheckedContinuation { continuation in
            reply.continuation = continuation
            reader.read(acknowledgedChange: acknowledged, boardName: name) { reply.complete($0) }
            // A broken coordinator must fail the test, not hang the whole suite.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { reply.complete(.failed) }
        }
    }

    @MainActor
    func testPrivatePipeCarriesUnicodeAndAcknowledgedCountArguments() async throws {
        let fixture = try Fixture("""
        assert sys.argv[1] == '--read-text-clipboard'
        assert sys.argv[sys.argv.index('--pasteboard-name') + 1] == 'CrossMouse-test-explicit'
        assert sys.argv[sys.argv.index('--acknowledged-change') + 1] == '19'
        payload = '다시 복사🙂\\n코드'.encode('utf-8')
        print(json.dumps({'kind':'text','changeCount':20,'utf8':base64.b64encode(payload).decode()}))
        """)
        let reader = TextClipboardReadProcess(executableURL: fixture.executable)
        defer { reader.cancel() }
        guard case .read(.text(let snapshot)) = await read(reader, acknowledged: 19, name: "CrossMouse-test-explicit")
        else { return XCTFail("Missing isolated Unicode result") }
        XCTAssertEqual(snapshot.changeCount, 20)
        XCTAssertEqual(snapshot.text, "다시 복사🙂\n코드")
    }

    @MainActor
    func testHungReadTimesOutWhileMainLoopRunsAndNextReadCanStart() async throws {
        let fixture = try Fixture("""
        if sys.argv[sys.argv.index('--pasteboard-name') + 1] == 'CrossMouse-test-hang':
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(30)
        print(json.dumps({'kind':'unchanged'}))
        """)
        let reader = TextClipboardReadProcess(executableURL: fixture.executable, timeout: 0.6)
        defer { reader.cancel() }
        let observation = Reply()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { observation.pulse = true }
        let start = ProcessInfo.processInfo.systemUptime
        guard case .timedOut = await read(reader, name: "CrossMouse-test-hang")
        else { return XCTFail("Native wait was not bounded") }
        XCTAssertTrue(observation.pulse)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.2)
        // Includes the previous child's TERM -> KILL/reap path. No native read
        // thread survives to block this replacement request.
        let next = await read(reader)
        guard case .read(.unchanged) = next
        else { return XCTFail("Timed-out child blocked the next copy: " + outcomeName(next)) }
    }

    @MainActor
    func testCancelSuppressesCompletionAndImmediateReplacementUsesFreshResult() async throws {
        let fixture = try Fixture("""
        name = sys.argv[sys.argv.index('--pasteboard-name') + 1]
        if name == 'CrossMouse-test-slow':
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            from pathlib import Path
            Path(__file__).with_name('ready').touch()
            time.sleep(30)
        print(json.dumps({'kind':'text','changeCount':42,'utf8':base64.b64encode(b'new-copy').decode()}))
        """)
        // This test asserts cancellation/identity, not interpreter startup
        // speed. The native integration separately verifies the 1 s budget.
        let reader = TextClipboardReadProcess(executableURL: fixture.executable, timeout: 2)
        defer { reader.cancel() }
        let observation = Reply()
        reader.read(acknowledgedChange: nil, boardName: "CrossMouse-test-slow") { _ in observation.count += 1 }
        let readyPath = fixture.directory.appendingPathComponent("ready").path
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !FileManager.default.fileExists(atPath: readyPath),
              ProcessInfo.processInfo.systemUptime < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard FileManager.default.fileExists(atPath: readyPath) else {
            return XCTFail("TERM-resistant fixture did not become ready")
        }
        reader.cancel()
        let next = await read(reader)
        guard case .read(.text(let snapshot)) = next else { return XCTFail("Replacement lost: " + outcomeName(next)) }
        XCTAssertEqual(snapshot.text, "new-copy")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(observation.count, 0)
    }

    @MainActor
    func testRapidReplacementsHaveOnlyNewestCompletion() async throws {
        let fixture = try Fixture("""
        time.sleep(0.05)
        print(json.dumps({'kind':'unchanged'}))
        """)
        let reader = TextClipboardReadProcess(executableURL: fixture.executable)
        defer { reader.cancel() }
        let observation = Reply()
        for _ in 0..<25 {
            reader.read(acknowledgedChange: nil, boardName: "CrossMouse-test-replaced") { _ in observation.count += 1 }
        }
        guard case .read(.unchanged) = await read(reader) else { return XCTFail("Newest request lost") }
        XCTAssertEqual(observation.count, 0)
    }

    @MainActor
    func testClosedOutputDoesNotSpinOrDefeatChildDeadline() async throws {
        let fixture = try Fixture("""
        if sys.argv[sys.argv.index('--pasteboard-name') + 1] == 'CrossMouse-test-eof':
            import os
            os.close(1)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(30)
        print(json.dumps({'kind':'unchanged'}))
        """)
        let reader = TextClipboardReadProcess(executableURL: fixture.executable, timeout: 0.6)
        defer { reader.cancel() }
        guard case .timedOut = await read(reader, name: "CrossMouse-test-eof")
        else { return XCTFail("EOF left a live child outside its deadline") }
        let next = await read(reader)
        guard case .read(.unchanged) = next
        else { return XCTFail("EOF child was not reaped before next read: " + outcomeName(next)) }
    }

    @MainActor
    func testMalformedOversizedAndCrashedHelpersFailWithoutPayloadLogging() async throws {
        for script in [
            "print('not-json')",
            "sys.stdout.write('x' * 400000); sys.stdout.flush(); time.sleep(5)",
            "sys.exit(7)",
            "print(json.dumps({'kind':'text','changeCount':1,'utf8':base64.b64encode(b'a\\x00b').decode()}))"
        ] {
            let fixture = try Fixture(script)
            let reader = TextClipboardReadProcess(executableURL: fixture.executable)
            guard case .failed = await read(reader) else { reader.cancel(); return XCTFail("Invalid helper output accepted") }
            reader.cancel()
        }
    }

    @MainActor
    func testFailedLaunchIsBoundedAndDoesNotRetainBusySlot() async {
        let reader = TextClipboardReadProcess(executableURL: URL(fileURLWithPath: "/CrossMouse-missing-test-helper"))
        defer { reader.cancel() }
        for _ in 0..<2 {
            guard case .failed = await read(reader) else { return XCTFail("Missing executable did not fail") }
        }
    }

    @MainActor
    func testInvalidNamedHelperArgumentsNeverReadGeneralPasteboard() {
        XCTAssertEqual(TextClipboardReadProcess.runHelperIfRequested(arguments:
            ["fixture", "--read-text-clipboard", "--pasteboard-name", ""]), 2)
        XCTAssertEqual(TextClipboardReadProcess.runHelperIfRequested(arguments:
            ["fixture", "--read-text-clipboard", "--pasteboard-name"]), 2)
        XCTAssertEqual(TextClipboardReadProcess.runHelperIfRequested(arguments:
            ["fixture", "--read-text-clipboard", "--acknowledged-change", "not-a-number"]), 2)
        XCTAssertNil(TextClipboardReadProcess.runHelperIfRequested(arguments: ["fixture", "--startup-self-test"]))
    }
}

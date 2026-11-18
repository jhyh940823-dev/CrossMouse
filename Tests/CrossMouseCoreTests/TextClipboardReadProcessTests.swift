import Foundation
import Darwin
import XCTest
@testable import CrossMouseCore

final class TextClipboardReadProcessTests: XCTestCase {
    /// Match production's native executable boundary. Compile once outside the
    /// read deadline; no interpreter/bootstrap cost, shell descendants, AppKit,
    /// clipboard access, or user input is involved in these lifecycle tests.
    private final class Fixture {
        private static let compiled: Result<URL, Error> = Result { try compile() }
        let directory: URL
        let executable: URL
        init() throws {
            let compiled = try Self.compiled.get()
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CrossMouse-read-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            executable = directory.appendingPathComponent("reader")
            try FileManager.default.copyItem(at: compiled, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        var diagnostics: String {
            (try? String(contentsOf: directory.appendingPathComponent("lifecycle"), encoding: .utf8))
                ?? "fixture did not start"
        }
        deinit { try? FileManager.default.removeItem(at: directory) }

        private static func compile() throws -> URL {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CrossMouse-native-read-fixture-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = directory.appendingPathComponent("fixture.c")
            let binary = directory.appendingPathComponent("reader")
            try nativeSource.write(to: source, atomically: true, encoding: .utf8)
            let compiler = Process()
            let errors = Pipe()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["clang", "-std=c11", "-Wall", "-Wextra", source.path, "-o", binary.path]
            compiler.standardOutput = FileHandle.nullDevice
            compiler.standardError = errors
            try compiler.run()
            compiler.waitUntilExit()
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "clang failed"
            guard compiler.terminationStatus == 0 else {
                throw NSError(domain: "CrossMouseTestFixture", code: Int(compiler.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            return binary
        }

        private static let nativeSource = #"""
        #include <stdio.h>
        #include <string.h>
        #include <stdlib.h>
        #include <unistd.h>
        #include <signal.h>
        #include <time.h>
        #include <limits.h>
        static const char *executable;
        static void sibling(char *path, const char *name) {
            snprintf(path, PATH_MAX, "%s", executable);
            char *slash = strrchr(path, '/');
            if (slash) snprintf(slash + 1, PATH_MAX - (slash + 1 - path), "%s", name);
        }
        static void mark(const char *phase) {
            char path[PATH_MAX]; sibling(path, "lifecycle");
            FILE *f = fopen(path, "a");
            struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
            if (f) { fprintf(f, "%.6f pid=%d ppid=%d %s\n", now.tv_sec + now.tv_nsec / 1e9,
                             getpid(), getppid(), phase); fclose(f); }
        }
        static void ready(void) {
            signal(SIGTERM, SIG_IGN);
            char path[PATH_MAX]; sibling(path, "ready");
            FILE *f = fopen(path, "w");
            if (f) { fprintf(f, "%d", getpid()); fclose(f); }
            mark("term-ignored-ready");
        }
        static void pause_ms(long ms) {
            struct timespec delay = { ms / 1000, (ms % 1000) * 1000000 };
            nanosleep(&delay, NULL);
        }
        int main(int argc, char **argv) {
            executable = argv[0]; mark("started");
            const char *name = "";
            long acknowledged = -1;
            int mode = 0;
            for (int i = 1; i < argc; ++i) {
                if (!strcmp(argv[i], "--read-text-clipboard")) mode = 1;
                else if (!strcmp(argv[i], "--pasteboard-name") && i + 1 < argc) name = argv[++i];
                else if (!strcmp(argv[i], "--acknowledged-change") && i + 1 < argc) acknowledged = strtol(argv[++i], NULL, 10);
                else return 2;
            }
            if (!mode) return 2;
            if (!strcmp(name, "CrossMouse-test-slow") || !strcmp(name, "CrossMouse-test-hang")) {
                ready(); pause_ms(30000);
            } else if (!strcmp(name, "CrossMouse-test-eof")) {
                close(STDOUT_FILENO); ready(); mark("stdout-closed"); pause_ms(30000);
            } else if (!strcmp(name, "CrossMouse-test-replaced")) pause_ms(50);
            if (!strcmp(name, "CrossMouse-test-malformed")) puts("not-json");
            else if (!strcmp(name, "CrossMouse-test-oversized")) {
                for (int i = 0; i < 400000; ++i) putchar('x');
                fflush(stdout); pause_ms(5000);
            } else if (!strcmp(name, "CrossMouse-test-exit")) { mark("nonzero-exit"); return 7; }
            else if (!strcmp(name, "CrossMouse-test-nul")) puts("{\"kind\":\"text\",\"changeCount\":1,\"utf8\":\"YQBi\"}");
            else if (!strcmp(name, "CrossMouse-test-new-copy")) puts("{\"kind\":\"text\",\"changeCount\":42,\"utf8\":\"bmV3LWNvcHk=\"}");
            else if (!strcmp(name, "CrossMouse-test-explicit")) {
                if (acknowledged != 19) return 3;
                puts("{\"kind\":\"text\",\"changeCount\":20,\"utf8\":\"\#(Data("다시 복사🙂\n코드".utf8).base64EncodedString())\"}");
            } else puts("{\"kind\":\"unchanged\"}");
            mark("exiting");
            return 0;
        }
        """#
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
        let fixture = try Fixture()
        let reader = TextClipboardReadProcess(executableURL: fixture.executable)
        defer { reader.cancel() }
        guard case .read(.text(let snapshot)) = await read(reader, acknowledged: 19, name: "CrossMouse-test-explicit")
        else { return XCTFail("Missing isolated Unicode result") }
        XCTAssertEqual(snapshot.changeCount, 20)
        XCTAssertEqual(snapshot.text, "다시 복사🙂\n코드")
    }

    @MainActor
    func testHungReadTimesOutWhileMainLoopRunsAndNextReadCanStart() async throws {
        let fixture = try Fixture()
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
        else { return XCTFail("Timed-out child blocked the next copy: " + outcomeName(next) + "\n" + fixture.diagnostics) }
    }

    @MainActor
    func testCancelSuppressesCompletionAndImmediateReplacementUsesFreshResult() async throws {
        let fixture = try Fixture()
        // Cancellation must happen after the fixture has installed SIG_IGN.
        // The native integration separately verifies the production 1 s budget.
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
            return XCTFail("TERM-resistant fixture did not become ready\n" + fixture.diagnostics)
        }
        let oldPID = try XCTUnwrap(Int32(String(contentsOfFile: readyPath, encoding: .utf8)))
        reader.cancel()
        let next = await read(reader, name: "CrossMouse-test-new-copy")
        guard case .read(.text(let snapshot)) = next else {
            return XCTFail("Replacement lost: " + outcomeName(next) + "\n" + fixture.diagnostics)
        }
        XCTAssertEqual(snapshot.text, "new-copy")
        XCTAssertEqual(kill(oldPID, 0), -1, "Canceled child survived successful replacement")
        XCTAssertEqual(errno, ESRCH)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(observation.count, 0)
    }

    @MainActor
    func testRapidReplacementsHaveOnlyNewestCompletion() async throws {
        let fixture = try Fixture()
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
        let fixture = try Fixture()
        let reader = TextClipboardReadProcess(executableURL: fixture.executable, timeout: 0.6)
        defer { reader.cancel() }
        guard case .timedOut = await read(reader, name: "CrossMouse-test-eof")
        else { return XCTFail("EOF left a live child outside its deadline") }
        let next = await read(reader)
        guard case .read(.unchanged) = next
        else { return XCTFail("EOF child was not reaped before next read: " + outcomeName(next) + "\n" + fixture.diagnostics) }
    }

    @MainActor
    func testMalformedOversizedAndCrashedHelpersFailWithoutPayloadLogging() async throws {
        for mode in ["malformed", "oversized", "exit", "nul"] {
            let fixture = try Fixture()
            let reader = TextClipboardReadProcess(executableURL: fixture.executable)
            guard case .failed = await read(reader, name: "CrossMouse-test-" + mode) else {
                reader.cancel(); return XCTFail("Invalid helper output accepted: " + mode + "\n" + fixture.diagnostics)
            }
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

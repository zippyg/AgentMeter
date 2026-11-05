import Darwin
import Foundation
import Testing
@testable import CodexBarCore

struct SubprocessRunnerTests {
    @Test
    func `reads large stdout without deadlock`() async throws {
        let byteCount = 256_000
        let result = try await SubprocessRunner.run(
            binary: "/usr/bin/python3",
            arguments: ["-c", "import sys; sys.stdout.write('x' * \(byteCount)); sys.stdout.flush()"],
            environment: ProcessInfo.processInfo.environment,
            timeout: 15,
            label: "python large stdout")

        #expect(result.stdout.count == byteCount)
        #expect(result.stderr.isEmpty)
    }

    @Test
    func `rejects truncated stdout explicitly`() async throws {
        let byteCount = 3_000_000
        do {
            _ = try await SubprocessRunner.run(
                binary: "/usr/bin/python3",
                arguments: ["-c", "import sys; sys.stdout.write('y' * \(byteCount)); sys.stdout.flush()"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 15,
                label: "python capped stdout")
            Issue.record("Expected output-limit error")
        } catch let error as SubprocessRunnerError {
            guard case let .outputLimitExceeded(label) = error else {
                Issue.record("Expected output-limit error, got \(error)")
                return
            }
            #expect(label == "python capped stdout")
        } catch {
            Issue.record("Expected SubprocessRunnerError, got \(error)")
        }
    }

    @Test
    func `rejects truncated stderr explicitly`() async throws {
        let byteCount = 3_000_000
        do {
            _ = try await SubprocessRunner.run(
                binary: "/usr/bin/python3",
                arguments: [
                    "-c",
                    "import sys; sys.stderr.write('z' * \(byteCount)); sys.stderr.flush(); sys.exit(7)",
                ],
                environment: ProcessInfo.processInfo.environment,
                timeout: 15,
                label: "python capped stderr")
            Issue.record("Expected nonzero subprocess error")
        } catch let error as SubprocessRunnerError {
            guard case let .outputLimitExceeded(label) = error else {
                Issue.record("Expected output-limit error, got \(error)")
                return
            }
            #expect(label == "python capped stderr")
        } catch {
            Issue.record("Expected SubprocessRunnerError, got \(error)")
        }
    }

    /// Regression test for #474: a hung subprocess must be killed and throw `.timedOut`
    /// instead of blocking indefinitely.
    ///
    /// This test was previously deleted (commit 3961770) because `waitUntilExit()` blocked
    /// the cooperative thread pool, starving the timeout task. The fix moves blocking calls
    /// to `DispatchQueue.global()`, making this test reliable.
    @Test
    func `throws timed out when process hangs`() async throws {
        let start = Date()
        do {
            _ = try await SubprocessRunner.run(
                binary: "/bin/sleep",
                arguments: ["30"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 1,
                label: "hung-process-test")
            Issue.record("Expected SubprocessRunnerError.timedOut but no error was thrown")
        } catch let error as SubprocessRunnerError {
            guard case let .timedOut(label) = error else {
                Issue.record("Expected .timedOut, got \(error)")
                return
            }
            #expect(label == "hung-process-test")
        } catch {
            Issue.record("Expected SubprocessRunnerError.timedOut, got unexpected error: \(error)")
        }

        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 10, "Timeout should not wait for process to exit naturally")
    }

    /// Multiple concurrent hung subprocesses must all time out independently, proving that
    /// one blocked subprocess does not starve the timeout mechanism of others.
    /// This is the core scenario that caused the original permanent-refresh-stall bug.
    @Test
    func `concurrent hung processes all time out`() async {
        let start = Date()
        let count = 8

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    do {
                        _ = try await SubprocessRunner.run(
                            binary: "/bin/sleep",
                            arguments: ["30"],
                            environment: ProcessInfo.processInfo.environment,
                            timeout: 2,
                            label: "concurrent-hung-\(i)")
                        Issue.record("Expected .timedOut for concurrent-hung-\(i)")
                    } catch let error as SubprocessRunnerError {
                        guard case .timedOut = error else {
                            Issue.record("Expected .timedOut for concurrent-hung-\(i), got \(error)")
                            return
                        }
                    } catch {
                        Issue.record("Unexpected error for concurrent-hung-\(i): \(error)")
                    }
                }
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        // Under release-load parallel tests the runner can be CPU-starved, but it should still finish far before
        // the natural sleep exit and below a serial 8 * 2s timeout chain.
        #expect(
            elapsed < 15,
            "All \(count) concurrent timeouts should fire in ~2s, took \(elapsed)s")
    }

    /// Stress-test the timeout race guard: with very short timeouts, the exit-code task
    /// and the timeout task race tightly, exercising the KillFlag synchronization path.
    @Test
    func `timeout race stress`() async {
        for i in 0..<20 {
            do {
                _ = try await SubprocessRunner.run(
                    binary: "/bin/sleep",
                    arguments: ["1"],
                    environment: ProcessInfo.processInfo.environment,
                    timeout: 0.1,
                    label: "race-stress-\(i)")
                Issue.record("Expected .timedOut for iteration \(i)")
            } catch let error as SubprocessRunnerError {
                guard case .timedOut = error else {
                    Issue.record("Expected .timedOut, got \(error) at iteration \(i)")
                    continue
                }
            } catch {
                Issue.record("Unexpected error at iteration \(i): \(error)")
            }
        }
    }

    @Test
    func `cancellation terminates hung process promptly`() async throws {
        let start = Date()
        let task = Task {
            try await SubprocessRunner.run(
                binary: "/bin/sleep",
                arguments: ["10"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 30,
                label: "cancelled-hung-process")
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError but subprocess completed")
        } catch is CancellationError {
            // Expected: cancellation should tear down the child process immediately.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5, "Cancelled subprocess should not wait for timeout or natural exit")
    }

    @Test
    func `timeout terminates child process tree`() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-subprocess-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        do {
            _ = try await SubprocessRunner.run(
                binary: "/usr/bin/python3",
                arguments: [
                    "-c",
                    """
                    import pathlib, subprocess, sys, time
                    child = subprocess.Popen(['/bin/sleep', '30'])
                    pathlib.Path(sys.argv[1]).write_text(str(child.pid))
                    sys.stdout.write('ready\\n')
                    sys.stdout.flush()
                    time.sleep(30)
                    """,
                    pidFile.path,
                ],
                environment: ProcessInfo.processInfo.environment,
                timeout: 1,
                label: "child-tree-timeout")
            Issue.record("Expected timeout")
        } catch let error as SubprocessRunnerError {
            guard case .timedOut = error else {
                Issue.record("Expected timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected SubprocessRunnerError, got \(error)")
        }

        let childPIDText = (try? String(contentsOf: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = childPIDText.flatMap { pid_t($0) }
        guard let childPID else {
            Issue.record("Child PID was not recorded")
            return
        }
        defer { kill(childPID, SIGKILL) }

        try await Task.sleep(for: .milliseconds(250))
        #expect(Self.processIsRunning(childPID) == false)
    }

    /// Verify that many concurrent SubprocessRunner calls complete without starving each other.
    @Test
    func `concurrent calls do not starve`() async throws {
        try await withThrowingTaskGroup(of: SubprocessResult.self) { group in
            for i in 0..<20 {
                group.addTask {
                    try await SubprocessRunner.run(
                        binary: "/bin/sleep",
                        arguments: ["0.2"],
                        environment: ProcessInfo.processInfo.environment,
                        timeout: 10,
                        label: "concurrent-\(i)")
                }
            }

            var count = 0
            for try await _ in group {
                count += 1
            }
            #expect(count == 20, "All 20 concurrent calls should complete")
        }
    }

    private static func processIsRunning(_ pid: pid_t) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "stat=", "-p", "\(pid)"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return kill(pid, 0) == 0
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !output.isEmpty && !output.hasPrefix("Z")
    }
}

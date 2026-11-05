#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

public enum SubprocessRunnerError: LocalizedError, Sendable {
    case binaryNotFound(String)
    case launchFailed(String)
    case timedOut(String)
    case outputLimitExceeded(String)
    case nonZeroExit(code: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .binaryNotFound(binary):
            return "Missing CLI '\(binary)'. Install it and restart AgentMeter."
        case let .launchFailed(details):
            return "Failed to launch process: \(details)"
        case let .timedOut(label):
            return "Command timed out: \(label)"
        case let .outputLimitExceeded(label):
            return "Command output exceeded the capture limit: \(label)"
        case let .nonZeroExit(code, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Command failed with exit code \(code)."
            }
            return "Command failed (\(code)): \(trimmed)"
        }
    }
}

public struct SubprocessResult: Sendable {
    public let stdout: String
    public let stderr: String
}

public enum SubprocessRunner {
    private static let log = CodexBarLog.logger(LogCategories.subprocess)
    private static let maxCapturedOutputBytes = 2 * 1024 * 1024
    private static let timeoutQueue = DispatchQueue(
        label: "com.zain.agentmeter.subprocess.timeout",
        qos: .userInitiated,
        attributes: .concurrent)

    /// Thread-safe flag for communicating between concurrent tasks (e.g. timeout → caller).
    private final class KillFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            self.lock.withLock { self.value = true }
        }

        var isSet: Bool {
            self.lock.withLock { self.value }
        }
    }

    private final class TimeoutTimer: @unchecked Sendable {
        private let timer: any DispatchSourceTimer

        init(timer: any DispatchSourceTimer) {
            self.timer = timer
        }

        func cancel() {
            self.timer.cancel()
        }
    }

    private static func timeoutInterval(_ timeout: TimeInterval) -> DispatchTimeInterval {
        guard timeout.isFinite else {
            return .seconds(Int.max)
        }
        let nanoseconds = max(0, timeout * 1_000_000_000).rounded(.towardZero)
        return .nanoseconds(Int(exactly: nanoseconds) ?? Int.max)
    }

    private final class ProcessTermination: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var continuation: CheckedContinuation<Int32, Never>?

        func resolve(_ status: Int32) {
            let continuation: CheckedContinuation<Int32, Never>?
            self.lock.lock()
            self.status = status
            continuation = self.continuation
            self.continuation = nil
            self.lock.unlock()
            continuation?.resume(returning: status)
        }

        func wait() async -> Int32 {
            await withCheckedContinuation { continuation in
                let status: Int32?
                self.lock.lock()
                status = self.status
                if status == nil {
                    self.continuation = continuation
                }
                self.lock.unlock()

                if let status {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    // MARK: - Helpers to move blocking calls off the cooperative thread pool

    private struct BoundedOutput: Sendable {
        var data = Data()
        var truncated = false

        mutating func append(_ chunk: Data, maxBytes: Int) {
            guard maxBytes > 0 else {
                self.data.removeAll(keepingCapacity: false)
                self.truncated = true
                return
            }
            if chunk.count >= maxBytes {
                self.data = Data(chunk.suffix(maxBytes))
                self.truncated = true
                return
            }
            if self.data.count + chunk.count > maxBytes {
                let overflow = self.data.count + chunk.count - maxBytes
                self.data.removeFirst(overflow)
                self.truncated = true
            }
            self.data.append(chunk)
        }
    }

    /// Polling owned pipe descriptors bounds drain time even when a child inherits a pipe and outlives its parent.
    private static func readDataOffPool(
        _ fileHandle: FileHandle,
        maxBytes: Int,
        stop: KillFlag) async -> BoundedOutput
    {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let fd = fileHandle.fileDescriptor
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let chunkSize = 64 * 1024
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                var output = BoundedOutput()
                while !stop.isSet {
                    let ready = poll(&descriptor, 1, 100)
                    if ready == 0 { continue }
                    if ready < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    guard descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else { break }
                    let count = read(fd, &buffer, chunkSize)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    output.append(Data(buffer.prefix(count)), maxBytes: maxBytes)
                }
                continuation.resume(returning: output)
            }
        }
    }

    private static func closePipeHandles(_ pipes: Pipe...) {
        for pipe in pipes {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }

    private static func directChildPIDs(of pid: pid_t) -> [pid_t] {
        let pgrep = "/usr/bin/pgrep"
        guard FileManager.default.isExecutableFile(atPath: pgrep) else { return [] }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: pgrep)
        process.arguments = ["-P", "\(pid)"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        var out: [pid_t] = []
        var queue = [rootPID]
        var seen = Set<pid_t>([rootPID])
        while let pid = queue.first, out.count < 256 {
            queue.removeFirst()
            for child in self.directChildPIDs(of: pid) where !seen.contains(child) {
                seen.insert(child)
                out.append(child)
                queue.append(child)
            }
        }
        return out
    }

    private static func signal(_ pids: [pid_t], _ signal: Int32) {
        for pid in pids where pid > 1 {
            kill(pid, signal)
        }
    }

    /// Terminates a process and its process group, escalating from SIGTERM to SIGKILL.
    /// Returns `true` if the process was actually killed, `false` if it had already exited.
    @discardableResult
    private static func terminateProcess(_ process: Process, processGroup: pid_t?) -> Bool {
        guard process.isRunning else { return false }
        let rootPID = process.processIdentifier
        self.signal(self.descendantPIDs(of: rootPID), SIGTERM)
        process.terminate()
        if let pgid = processGroup {
            kill(-pgid, SIGTERM)
        }
        let killDeadline = Date().addingTimeInterval(0.4)
        while process.isRunning, Date() < killDeadline {
            usleep(50000)
        }
        if process.isRunning {
            self.signal(self.descendantPIDs(of: rootPID), SIGKILL)
            if let pgid = processGroup {
                kill(-pgid, SIGKILL)
            }
            kill(rootPID, SIGKILL)
        }
        return true
    }

    // MARK: - Public API

    public static func run(
        binary: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        standardInput: Any? = nil,
        currentDirectoryURL: URL? = nil,
        label: String) async throws -> SubprocessResult
    {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw SubprocessRunnerError.binaryNotFound(binary)
        }

        let start = Date()
        let binaryName = URL(fileURLWithPath: binary).lastPathComponent
        self.log.debug(
            "Subprocess start",
            metadata: [
                "label": label,
                "binary": binaryName,
                "timeout": "\(timeout)",
                "args": "\(arguments.count)",
            ])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = standardInput

        let termination = ProcessTermination()
        process.terminationHandler = { process in
            termination.resolve(process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            stdoutPipe.fileHandleForReading.closeFile()
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            throw SubprocessRunnerError.launchFailed(error.localizedDescription)
        }

        let pid = process.processIdentifier
        let processGroup: pid_t? = setpgid(pid, pid) == 0 ? pid : nil

        let stopReading = KillFlag()
        let stdoutTask = Task<BoundedOutput, Never> {
            await self.readDataOffPool(
                stdoutPipe.fileHandleForReading,
                maxBytes: self.maxCapturedOutputBytes,
                stop: stopReading)
        }
        let stderrTask = Task<BoundedOutput, Never> {
            await self.readDataOffPool(
                stderrPipe.fileHandleForReading,
                maxBytes: self.maxCapturedOutputBytes,
                stop: stopReading)
        }

        let exitCodeTask = Task<Int32, Never> {
            await termination.wait()
        }

        let killedByTimeout = KillFlag()
        let timeoutTimer = DispatchSource.makeTimerSource(queue: self.timeoutQueue)
        timeoutTimer.schedule(deadline: .now() + self.timeoutInterval(timeout))
        timeoutTimer.setEventHandler {
            killedByTimeout.set()
            stopReading.set()
            self.terminateProcess(process, processGroup: processGroup)
        }
        timeoutTimer.resume()
        let timeoutTimerBox = TimeoutTimer(timer: timeoutTimer)
        defer {
            timeoutTimerBox.cancel()
            self.closePipeHandles(stdoutPipe, stderrPipe)
            process.terminationHandler = nil
        }

        do {
            let (exitCode, stdoutOutput, stderrOutput) = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let code = await exitCodeTask.value
                let stdout = await stdoutTask.value
                let stderr = await stderrTask.value
                try Task.checkCancellation()
                return (code, stdout, stderr)
            } onCancel: {
                timeoutTimerBox.cancel()
                stopReading.set()
                self.terminateProcess(process, processGroup: processGroup)
            }
            timeoutTimerBox.cancel()

            let duration = Date().timeIntervalSince(start)
            // Race guard: the timeout timer may kill the process just before the
            // exit code arrives. Key off the explicit kill flag so a completed
            // process is not misclassified when the awaiting task resumes late.
            if killedByTimeout.isSet {
                self.log.warning(
                    "Subprocess timed out",
                    metadata: [
                        "label": label,
                        "binary": binaryName,
                        "duration_ms": "\(Int(duration * 1000))",
                    ])
                stdoutTask.cancel()
                stderrTask.cancel()
                throw SubprocessRunnerError.timedOut(label)
            }

            guard !stdoutOutput.truncated, !stderrOutput.truncated else {
                throw SubprocessRunnerError.outputLimitExceeded(label)
            }
            let stdout = String(data: stdoutOutput.data, encoding: .utf8) ?? ""
            let stderr = String(data: stderrOutput.data, encoding: .utf8) ?? ""

            if exitCode != 0 {
                let duration = Date().timeIntervalSince(start)
                self.log.warning(
                    "Subprocess failed",
                    metadata: [
                        "label": label,
                        "binary": binaryName,
                        "status": "\(exitCode)",
                        "duration_ms": "\(Int(duration * 1000))",
                    ])
                throw SubprocessRunnerError.nonZeroExit(code: exitCode, stderr: stderr)
            }

            self.log.debug(
                "Subprocess exit",
                metadata: [
                    "label": label,
                    "binary": binaryName,
                    "status": "\(exitCode)",
                    "duration_ms": "\(Int(duration * 1000))",
                ])
            return SubprocessResult(stdout: stdout, stderr: stderr)
        } catch {
            let duration = Date().timeIntervalSince(start)
            self.log.warning(
                "Subprocess error",
                metadata: [
                    "label": label,
                    "binary": binaryName,
                    "duration_ms": "\(Int(duration * 1000))",
                ])
            // Safety net: ensure the process is dead (may already be killed by timeout timer).
            stopReading.set()
            self.terminateProcess(process, processGroup: processGroup)
            _ = await stdoutTask.value
            _ = await stderrTask.value
            exitCodeTask.cancel()
            stdoutTask.cancel()
            stderrTask.cancel()
            throw error
        }
    }
}

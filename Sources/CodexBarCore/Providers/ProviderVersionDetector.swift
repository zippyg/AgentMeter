#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

public enum ProviderVersionDetector {
    private static let claudeVersionLock = NSLock()
    nonisolated(unsafe) private static var claudeVersionCache: [String: (checkedAt: Date, version: String?)] = [:]

    public static func claudeVersion(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        guard let path = ClaudeCLIResolver.resolvedBinaryPath(environment: environment) else { return nil }
        return self.detectClaudeVersion(path: path) { self.runClaudeVersionCommand(path: path) }
    }

    static func detectClaudeVersion(path: String, now: Date = Date(), probe: () -> String?) -> String? {
        self.claudeVersionLock.withLock {
            if ProviderInteractionContext.current == .background,
               let cached = self.claudeVersionCache[path],
               now.timeIntervalSince(cached.checkedAt) < 5 * 60
            {
                return cached.version
            }
            let version = probe()
            self.claudeVersionCache[path] = (now, version)
            return version
        }
    }

    private static func runClaudeVersionCommand(path: String) -> String? {
        do {
            let out = try TTYCommandRunner().run(
                binary: path,
                send: "",
                options: TTYCommandRunner.Options(
                    timeout: 5.0,
                    extraArgs: ["--allowed-tools", "", "--version"],
                    initialDelay: 0.0,
                    useClaudeProbeWorkingDirectory: true)).text
            let trimmed = TextParsing.stripANSICodes(out).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    public static func codexVersion() -> String? {
        guard let path = TTYCommandRunner.which("codex") else { return nil }
        let candidates = [
            ["--version"],
            ["version"],
            ["-v"],
        ]
        for args in candidates {
            if let version = Self.run(path: path, args: args) { return version }
        }
        return nil
    }

    public static func geminiVersion() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let path = BinaryLocator.resolveGeminiBinary(env: env, loginPATH: nil)
            ?? TTYCommandRunner.which("gemini") else { return nil }
        let candidates = [
            ["--version"],
            ["-v"],
        ]
        for args in candidates {
            if let version = Self.run(path: path, args: args) { return version }
        }
        return nil
    }

    static func run(path: String, args: [String], timeout: TimeInterval = 2.0) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        proc.standardInput = nil

        let exitSemaphore = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in
            exitSemaphore.signal()
        }

        do {
            try proc.run()
        } catch {
            return nil
        }

        let didExit = exitSemaphore.wait(timeout: .now() + timeout) == .success
        if !didExit, !Self.forceExit(proc, exitSemaphore: exitSemaphore) {
            return nil
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                  .split(whereSeparator: \.isNewline).first
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func forceExit(_ proc: Process, exitSemaphore: DispatchSemaphore) -> Bool {
        guard proc.isRunning else { return true }

        proc.terminate()
        if exitSemaphore.wait(timeout: .now() + 0.5) == .success {
            return true
        }

        guard proc.isRunning else { return true }
        kill(proc.processIdentifier, SIGKILL)
        return exitSemaphore.wait(timeout: .now() + 1.0) == .success
    }
}

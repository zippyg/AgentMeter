import Foundation

/// Codex compresses session logs older than about a week to `.jsonl.zst`. This package has no
/// in-process zstd decoder, so compressed logs stream through the system `zstd` binary when one is
/// installed. Without it they are skipped and a warning names how many were left out.
enum CostUsageLogFile {
    enum ReadError: LocalizedError {
        case zstdUnavailable
        case zstdFailed(status: Int32)

        var errorDescription: String? {
            switch self {
            case .zstdUnavailable: "zstd is not installed, so compressed Codex logs (.jsonl.zst) cannot be read"
            case let .zstdFailed(status): "zstd exited with status \(status) while reading a compressed Codex log"
            }
        }
    }

    static let zstdCandidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]

    static let systemZstdPath: String? = zstdCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }

    /// The zstd binary in use. Task-local so tests can simulate a missing or broken binary.
    @TaskLocal static var zstdPath: String? = systemZstdPath

    static func isCompressed(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(".jsonl.zst")
    }

    /// Plain `.jsonl`, or `.jsonl.zst` when zstd is available to read it.
    static func isCodexSessionLog(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "jsonl" { return true }
        guard self.isCompressed(url) else { return false }
        if self.zstdPath != nil { return true }
        self.warnSkipped(url)
        return false
    }

    private static let skippedLock = NSLock()
    private nonisolated(unsafe) static var skippedCount = 0

    private static func warnSkipped(_ url: URL) {
        let count = self.skippedLock.withLock {
            self.skippedCount += 1
            return self.skippedCount
        }
        // Log the first skip and then every hundredth, so the gap stays visible without flooding.
        guard count == 1 || count % 100 == 0 else { return }
        CostUsageScanner.log.warning(
            "Codex cost usage skipped compressed session logs",
            metadata: ["skipped": "\(count)", "reason": ReadError.zstdUnavailable.errorDescription ?? ""])
    }

    /// Reads a session log's decompressed bytes in order. Seeking forward discards bytes.
    final class Reader {
        private let handle: FileHandle
        private let process: Process?

        init(url: URL) throws {
            guard CostUsageLogFile.isCompressed(url) else {
                self.handle = try FileHandle(forReadingFrom: url)
                self.process = nil
                return
            }
            guard let zstd = CostUsageLogFile.zstdPath else { throw ReadError.zstdUnavailable }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: zstd)
            process.arguments = ["-dcq", "--", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw ReadError.zstdUnavailable
            }
            self.handle = pipe.fileHandleForReading
            self.process = process
        }

        func read(upToCount count: Int) throws -> Data? {
            let data = try self.handle.read(upToCount: count)
            if data?.isEmpty ?? true, let process = self.process {
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw ReadError.zstdFailed(status: process.terminationStatus)
                }
            }
            return data
        }

        func seek(toOffset offset: UInt64) throws {
            guard self.process != nil else { return try self.handle.seek(toOffset: offset) }
            var remaining = offset
            while remaining > 0 {
                guard let data = try self.read(upToCount: Int(min(remaining, 256 * 1024))),
                      !data.isEmpty else { return }
                remaining -= UInt64(data.count)
            }
        }

        func close() {
            try? self.handle.close()
            if let process = self.process, process.isRunning {
                // Metadata readers stop before EOF. A decompressor can inherit an ignored
                // SIGTERM, so terminate it unconditionally before synchronously reaping it.
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
    }
}

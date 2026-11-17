import Foundation

/// Whether the token scan saw every log, per provider. A scan records the roots it read and the files
/// its cache holds; this compares them with what is on disk now, so a skipped or unreadable file
/// shows up as a count instead of silently missing tokens.
public struct CostUsageScanStatus: Sendable, Equatable {
    public let provider: UsageProvider
    /// Log files changed inside the window.
    public let found: Int
    /// Found and counted from the cache.
    public let read: Int
    /// Of those read, compressed .jsonl.zst logs.
    public let compressedRead: Int
    /// Changed after the last scan; the next scan reads them.
    public let pending: Int
    /// Older than the last scan but absent from its cache: never listed, failed to read or decompress,
    /// or a duplicate copy of a session already counted.
    public let unread: Int
    /// Log-like files of a format this provider does not read, such as .jsonl.gz.
    public let skipped: Int
    public let scannedAt: Date

    public init(
        provider: UsageProvider,
        found: Int,
        read: Int,
        compressedRead: Int,
        pending: Int,
        unread: Int,
        skipped: Int,
        scannedAt: Date)
    {
        self.provider = provider
        self.found = found
        self.read = read
        self.compressedRead = compressedRead
        self.pending = pending
        self.unread = unread
        self.skipped = skipped
        self.scannedAt = scannedAt
    }

    /// What the scan's cache knew about one log.
    struct CachedFile: Sendable, Equatable {
        let mtimeUnixMs: Int64
        let size: Int64
        /// Bytes the parser got through. Zero for a non-empty file means it could not be read.
        let parsedBytes: Int64?
    }

    struct Record: Sendable {
        let roots: [URL]
        let files: [String: CachedFile]
        let scannedAt: Date
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var records: [UsageProvider: Record] = [:]

    static func record(_ provider: UsageProvider, roots: [URL], files: [String: CostUsageFileUsage], at date: Date) {
        let record = Record(
            roots: roots,
            files: files.mapValues { .init(mtimeUnixMs: $0.mtimeUnixMs, size: $0.size, parsedBytes: $0.parsedBytes) },
            scannedAt: date)
        self.lock.withLock { self.records[provider] = record }
    }

    /// Nil until a scan of this provider has run in this process. Lists the disk, so call it off the main thread.
    public static func current(_ provider: UsageProvider, since: Date) -> Self? {
        guard let record = self.lock.withLock({ self.records[provider] }) else { return nil }
        return self.compare(provider, record: record, since: since)
    }

    static func readable(_ provider: UsageProvider, name: String) -> Bool {
        let name = name.lowercased()
        return name.hasSuffix(".jsonl") || (provider == .codex && name.hasSuffix(".jsonl.zst"))
    }

    static func compare(_ provider: UsageProvider, record: Record, since: Date) -> Self {
        var found = 0, read = 0, compressed = 0, pending = 0, unread = 0, skipped = 0
        var seen: Set<String> = []
        // Compare resolved paths: the folder walk can spell a path through a symlink the scan did not.
        let cached = Dictionary(
            record.files.map { (URL(fileURLWithPath: $0.key).resolvingSymlinksInPath().path, $0.value) },
            uniquingKeysWith: { first, _ in first })
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        for root in record.roots {
            guard let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in files {
                let name = url.lastPathComponent
                guard name.lowercased().contains(".jsonl"), seen.insert(url.path).inserted,
                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= since else { continue }
                guard self.readable(provider, name: name) else {
                    skipped += 1
                    continue
                }
                found += 1
                guard let entry = record.files[url.path] ?? cached[url.resolvingSymlinksInPath().path] else {
                    if modified > record.scannedAt { pending += 1 } else { unread += 1 }
                    continue
                }
                let modifiedMs = Int64(modified.timeIntervalSince1970 * 1000)
                // Appended or rewritten since it was cached: the next scan reads the rest.
                if abs(modifiedMs - entry.mtimeUnixMs) > 1 || Int64(values.fileSize ?? 0) != entry.size {
                    pending += 1
                } else if entry.size > 0, (entry.parsedBytes ?? entry.size) == 0 {
                    // Cached as empty although it has bytes: it could not be opened or read.
                    unread += 1
                } else {
                    read += 1
                    if name.lowercased().hasSuffix(".zst") { compressed += 1 }
                }
            }
        }
        return Self(
            provider: provider,
            found: found,
            read: read,
            compressedRead: compressed,
            pending: pending,
            unread: unread,
            skipped: skipped,
            scannedAt: record.scannedAt)
    }
}

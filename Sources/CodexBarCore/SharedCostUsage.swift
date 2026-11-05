import Darwin
import Foundation

/// The shared boundary contains daily counters only, never transcript or account metadata.
public struct SharedCostUsage: Codable, Sendable {
    public static let schemaVersion = 1
    public static let directory = URL(fileURLWithPath: "/Users/Shared/AgentMeter", isDirectory: true)
    public static let maxAge: TimeInterval = 2 * 24 * 60 * 60

    public struct Model: Codable, Sendable {
        public let name: String
        public let tokens: Int?
        public let costUSD: Double?
    }

    public struct Day: Codable, Sendable {
        public let date: String
        public let inputTokens: Int?
        public let outputTokens: Int?
        public let cacheReadTokens: Int?
        public let cacheWriteTokens: Int?
        public let tokens: Int?
        public let costUSD: Double?
        public let requests: Int?
        public let models: [Model]
        /// Optional, so a reader built before it ignores the field: claude-swap slot keys or
        /// account fingerprints only, never account ids or names.
        public let accounts: [Model]?

        init(_ entry: CostUsageDailyReport.Entry) {
            self.date = entry.date
            self.inputTokens = entry.inputTokens
            self.outputTokens = entry.outputTokens
            self.cacheReadTokens = entry.cacheReadTokens
            self.cacheWriteTokens = entry.cacheCreationTokens
            self.tokens = entry.totalTokens
            self.costUSD = entry.costUSD
            self.requests = entry.requestCount
            self.models = (entry.modelBreakdowns ?? []).map {
                Model(name: $0.modelName, tokens: $0.totalTokens, costUSD: $0.costUSD)
            }
            self.accounts = entry.accountBreakdowns.map { $0.map {
                Model(name: $0.modelName, tokens: $0.totalTokens, costUSD: $0.costUSD)
            } }
        }

        var entry: CostUsageDailyReport.Entry {
            .init(
                date: self.date, inputTokens: self.inputTokens, outputTokens: self.outputTokens,
                cacheReadTokens: self.cacheReadTokens, cacheCreationTokens: self.cacheWriteTokens,
                totalTokens: self.tokens, requestCount: self.requests, costUSD: self.costUSD,
                modelsUsed: self.models.map(\.name), modelBreakdowns: self.models.map {
                    .init(modelName: $0.name, costUSD: $0.costUSD, totalTokens: $0.tokens)
                }, accountBreakdowns: self.accounts?.map {
                    .init(modelName: $0.name, costUSD: $0.costUSD, totalTokens: $0.tokens)
                })
        }
    }

    public struct Engine: Codable, Sendable {
        public let engine: String
        public let generatedAt: Date
        public let daily: [Day]

        public init(provider: UsageProvider, snapshot: CostUsageTokenSnapshot) {
            self.engine = provider.rawValue
            self.generatedAt = snapshot.updatedAt
            self.daily = snapshot.daily.map(Day.init)
        }

        public var report: CostUsageDailyReport {
            CostUsageDailyReport(data: self.daily.map(\.entry), summary: nil)
        }
    }

    public struct Source: Sendable {
        public let user: String
        public let usage: Engine
        public let stale: Bool

        public init(user: String, usage: Engine, stale: Bool) {
            self.user = user
            self.usage = usage
            self.stale = stale
        }
    }

    public let schemaVersion: Int
    public let generatedAt: Date
    public let user: String
    public let engines: [Engine]

    public init(user: String = NSUserName(), engines: [Engine], generatedAt: Date = Date()) {
        self.schemaVersion = Self.schemaVersion
        self.generatedAt = generatedAt
        self.user = user
        self.engines = engines.filter { ["claude", "codex"].contains($0.engine) }
    }

    public static func defaultURL(user: String = NSUserName(), directory: URL = Self.directory) -> URL {
        directory.appendingPathComponent("usage-\(user).json")
    }

    public static func read(at url: URL) throws -> SharedCostUsage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Self.self, from: Data(contentsOf: url))
        guard value.schemaVersion == Self.schemaVersion else {
            throw CocoaError(.coderReadCorrupt)
        }
        return value
    }

    public func write(to url: URL? = nil) throws {
        let destination = url ?? Self.defaultURL(user: self.user)
        let parent = destination.deletingLastPathComponent()
        try Self.prepareDirectory(parent, shared: parent.standardizedFileURL == Self.directory.standardizedFileURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        // Foundation writes a sibling temporary file and renames it over the destination.
        try encoder.encode(self).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
    }

    static func prepareDirectory(_ directory: URL, shared: Bool) throws {
        let permissions = shared ? 0o1777 : 0o755
        let created = !FileManager.default.fileExists(atPath: directory.path)
        if created {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: permissions])
        }
        if shared {
            let actual = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
            if created || actual != permissions {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: directory.path)
            }
        }
    }

    private static func ownerMatches(user: String, at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              attributes[.type] as? FileAttributeType == .typeRegular
        else { return false }
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: max(16384, Int(sysconf(_SC_GETPW_R_SIZE_MAX))))
        return getpwnam_r(user, &record, &buffer, buffer.count, &result) == 0
            && result != nil && owner.uint32Value == record.pw_uid
    }

    public static func importedSources(
        directory: URL = Self.directory,
        ownUser: String = NSUserName(),
        now: Date = Date()) -> [Source]
    {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).flatMap { url -> [Source] in
            guard url.lastPathComponent.hasPrefix("usage-"), url.pathExtension == "json",
                  url.lastPathComponent != Self.defaultURL(user: ownUser).lastPathComponent,
                  let aggregate = try? Self.read(at: url), aggregate.user != ownUser,
                  url.lastPathComponent == Self.defaultURL(user: aggregate.user).lastPathComponent,
                  Self.ownerMatches(user: aggregate.user, at: url)
            else { return [] }
            return aggregate.engines.filter { ["claude", "codex"].contains($0.engine) }.map { engine in
                Source(
                    user: aggregate.user, usage: engine,
                    stale: now.timeIntervalSince(aggregate.generatedAt) > Self.maxAge
                        || now.timeIntervalSince(engine.generatedAt) > Self.maxAge)
            }
        }
    }

    public static func mergedReport(sources: [Source], now: Date = Date()) -> CostUsageDailyReport {
        let today = CostUsageScanner.CostUsageDayRange.dayKey(from: now)
        let start = CostUsageScanner.CostUsageDayRange.dayKey(from:
            Calendar.current.date(byAdding: .day, value: -29, to: now) ?? now)
        return CostUsageDailyReport.merged(sources.filter { !$0.stale }.map { source in
            CostUsageDailyReport(
                data: source.usage.report.data.filter { $0.date >= start && $0.date <= today }, summary: nil)
        })
    }
}

public actor SharedCostUsageExchange {
    public static let shared = SharedCostUsageExchange()

    public func publish(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot,
        user: String = NSUserName(),
        directory: URL = SharedCostUsage.directory,
        now: Date = Date(),
        enabledProviders: Set<UsageProvider> = [.claude, .codex]) throws -> [SharedCostUsage.Source]
    {
        let url = SharedCostUsage.defaultURL(user: user, directory: directory)
        var engines = (try? SharedCostUsage.read(at: url))?.engines ?? []
        engines.removeAll { engine in
            engine.engine == provider.rawValue || !enabledProviders.contains { $0.rawValue == engine.engine }
        }
        if enabledProviders.contains(provider) {
            engines.append(.init(provider: provider, snapshot: snapshot))
        }
        try SharedCostUsage(user: user, engines: engines, generatedAt: now).write(to: url)
        return SharedCostUsage.importedSources(directory: directory, ownUser: user, now: now)
    }
}

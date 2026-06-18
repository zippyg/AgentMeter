import Foundation

public struct AgentMeterPhoneSnapshot: Codable, Equatable, Sendable {
    public static let primaryProviderIDs: Set<String> = ["claude", "codex"]
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let snapshotSequence: Int
    public let generatedAt: Date
    public let producer: AgentMeterSnapshotProducer?
    public let providers: [AgentMeterPhoneProvider]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        snapshotSequence: Int = 0,
        generatedAt: Date,
        producer: AgentMeterSnapshotProducer? = nil,
        providers: [AgentMeterPhoneProvider])
    {
        self.schemaVersion = schemaVersion
        self.snapshotSequence = snapshotSequence
        self.generatedAt = generatedAt
        self.producer = producer
        self.providers = providers
    }

    public init(
        widgetSnapshot: WidgetSnapshot,
        metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata,
        staleInterval: TimeInterval = 15 * 60,
        providerIDs: Set<String> = Self.primaryProviderIDs)
    {
        let agentMeterSnapshot = AgentMeterSnapshot(
            widgetSnapshot: widgetSnapshot,
            metadata: metadata,
            staleInterval: staleInterval)
        var dailyUsageByProvider: [String: [WidgetSnapshot.DailyUsagePoint]] = [:]
        for entry in widgetSnapshot.entries {
            dailyUsageByProvider[entry.provider.rawValue] = entry.dailyUsage
        }

        self.init(
            agentMeterSnapshot: agentMeterSnapshot,
            dailyUsageByProvider: dailyUsageByProvider,
            providerIDs: providerIDs)
    }

    public init(
        agentMeterSnapshot: AgentMeterSnapshot,
        providerIDs: Set<String> = Self.primaryProviderIDs)
    {
        self.init(
            agentMeterSnapshot: agentMeterSnapshot,
            dailyUsageByProvider: [:],
            providerIDs: providerIDs)
    }

    public init(
        agentMeterSnapshot: AgentMeterSnapshot,
        dailyUsageByProvider: [String: [WidgetSnapshot.DailyUsagePoint]],
        providerIDs: Set<String> = Self.primaryProviderIDs)
    {
        self.init(
            schemaVersion: agentMeterSnapshot.schemaVersion,
            snapshotSequence: agentMeterSnapshot.snapshotSequence,
            generatedAt: agentMeterSnapshot.generatedAt,
            producer: agentMeterSnapshot.producer,
            providers: agentMeterSnapshot.providers
                .filter { providerIDs.contains($0.id) }
                .map { provider in
                    AgentMeterPhoneProvider(
                        provider: provider,
                        dailyUsage: dailyUsageByProvider[provider.id, default: []])
                })
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case snapshotSequence
        case generatedAt
        case producer
        case providers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.snapshotSequence = try container.decodeIfPresent(Int.self, forKey: .snapshotSequence) ?? 0
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.producer = try container.decodeIfPresent(AgentMeterSnapshotProducer.self, forKey: .producer)
        self.providers = try container.decode([AgentMeterPhoneProvider].self, forKey: .providers)
    }
}

public struct AgentMeterPhoneProvider: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let accountLabel: String?
    public let plan: String?
    public let windows: [AgentMeterPhoneUsageWindow]
    public let tokenUsage: AgentMeterPhoneTokenUsage?
    public let dailyUsage: [AgentMeterPhoneDailyUsagePoint]
    public let source: AgentMeterPhoneSource
    public let status: AgentMeterPhoneProviderStatus
    public let updatedAt: Date
    public let staleAfter: Date?
    public let nextRefreshAt: Date?
    public let lastError: String?

    public init(
        id: String,
        displayName: String,
        accountLabel: String? = nil,
        plan: String? = nil,
        windows: [AgentMeterPhoneUsageWindow],
        tokenUsage: AgentMeterPhoneTokenUsage? = nil,
        dailyUsage: [AgentMeterPhoneDailyUsagePoint] = [],
        source: AgentMeterPhoneSource,
        status: AgentMeterPhoneProviderStatus,
        updatedAt: Date,
        staleAfter: Date?,
        nextRefreshAt: Date? = nil,
        lastError: String? = nil)
    {
        self.id = id
        self.displayName = displayName
        self.accountLabel = accountLabel
        self.plan = plan
        self.windows = windows
        self.tokenUsage = tokenUsage
        self.dailyUsage = dailyUsage
        self.source = source
        self.status = status
        self.updatedAt = updatedAt
        self.staleAfter = staleAfter
        self.nextRefreshAt = nextRefreshAt
        self.lastError = lastError
    }

    public init(provider: AgentMeterProviderSnapshot, dailyUsage: [WidgetSnapshot.DailyUsagePoint]) {
        self.init(
            id: provider.id,
            displayName: provider.displayName,
            accountLabel: provider.accountLabel,
            plan: provider.plan,
            windows: provider.windows.map(AgentMeterPhoneUsageWindow.init(window:)),
            tokenUsage: provider.tokenUsage.map(AgentMeterPhoneTokenUsage.init(tokenUsage:)),
            dailyUsage: dailyUsage.map(AgentMeterPhoneDailyUsagePoint.init(point:)),
            source: AgentMeterPhoneSource(source: provider.source),
            status: AgentMeterPhoneProviderStatus(provider.status),
            updatedAt: provider.updatedAt,
            staleAfter: provider.staleAfter,
            nextRefreshAt: provider.nextRefreshAt,
            lastError: provider.lastError)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case accountLabel
        case plan
        case windows
        case tokenUsage
        case dailyUsage
        case source
        case status
        case updatedAt
        case staleAfter
        case nextRefreshAt
        case lastError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel)
        self.plan = try container.decodeIfPresent(String.self, forKey: .plan)
        self.windows = try container.decode([AgentMeterPhoneUsageWindow].self, forKey: .windows)
        self.tokenUsage = try container.decodeIfPresent(AgentMeterPhoneTokenUsage.self, forKey: .tokenUsage)
        self.dailyUsage = try container.decodeIfPresent(
            [AgentMeterPhoneDailyUsagePoint].self,
            forKey: .dailyUsage) ?? []
        self.source = try container.decode(AgentMeterPhoneSource.self, forKey: .source)
        self.status = try container.decodeIfPresent(AgentMeterPhoneProviderStatus.self, forKey: .status) ?? .ok
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.staleAfter = try container.decodeIfPresent(Date.self, forKey: .staleAfter)
        self.nextRefreshAt = try container.decodeIfPresent(Date.self, forKey: .nextRefreshAt)
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

public struct AgentMeterPhoneUsageWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let usedPercent: Double?
    public let remainingPercent: Double?
    public let resetsAt: Date?
    public let resetDescription: String?
    public let windowMinutes: Int?

    public init(
        id: String,
        title: String,
        usedPercent: Double?,
        remainingPercent: Double?,
        resetsAt: Date?,
        resetDescription: String?,
        windowMinutes: Int?)
    {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.windowMinutes = windowMinutes
    }

    public init(window: AgentMeterUsageWindow) {
        self.init(
            id: window.id,
            title: window.title,
            usedPercent: window.usedPercent,
            remainingPercent: window.remainingPercent,
            resetsAt: window.resetsAt,
            resetDescription: window.resetDescription,
            windowMinutes: window.windowMinutes)
    }
}

public struct AgentMeterPhoneTokenUsage: Codable, Equatable, Sendable {
    public let sessionCostUSD: Double?
    public let sessionTokens: Int?
    public let last30DaysCostUSD: Double?
    public let last30DaysTokens: Int?
    public let currencyCode: String
    public let sessionLabel: String
    public let last30DaysLabel: String

    public init(
        sessionCostUSD: Double?,
        sessionTokens: Int?,
        last30DaysCostUSD: Double?,
        last30DaysTokens: Int?,
        currencyCode: String,
        sessionLabel: String,
        last30DaysLabel: String)
    {
        self.sessionCostUSD = sessionCostUSD
        self.sessionTokens = sessionTokens
        self.last30DaysCostUSD = last30DaysCostUSD
        self.last30DaysTokens = last30DaysTokens
        self.currencyCode = currencyCode
        self.sessionLabel = sessionLabel
        self.last30DaysLabel = last30DaysLabel
    }

    public init(tokenUsage: AgentMeterTokenUsageSummary) {
        self.init(
            sessionCostUSD: tokenUsage.sessionCostUSD,
            sessionTokens: tokenUsage.sessionTokens,
            last30DaysCostUSD: tokenUsage.last30DaysCostUSD,
            last30DaysTokens: tokenUsage.last30DaysTokens,
            currencyCode: tokenUsage.currencyCode,
            sessionLabel: tokenUsage.sessionLabel,
            last30DaysLabel: tokenUsage.last30DaysLabel)
    }
}

public struct AgentMeterPhoneDailyUsagePoint: Codable, Equatable, Sendable {
    public let dayKey: String
    public let totalTokens: Int?
    public let costUSD: Double?

    public init(dayKey: String, totalTokens: Int?, costUSD: Double?) {
        self.dayKey = dayKey
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }

    public init(point: WidgetSnapshot.DailyUsagePoint) {
        self.init(dayKey: point.dayKey, totalTokens: point.totalTokens, costUSD: point.costUSD)
    }
}

public struct AgentMeterPhoneSource: Codable, Equatable, Sendable {
    public let confidence: AgentMeterPhoneSourceConfidence
    public let label: String
    public let detail: String?

    public init(confidence: AgentMeterPhoneSourceConfidence, label: String, detail: String? = nil) {
        self.confidence = confidence
        self.label = label
        self.detail = detail
    }

    public init(source: AgentMeterSourceDescriptor) {
        self.init(
            confidence: AgentMeterPhoneSourceConfidence(source.confidence),
            label: source.label,
            detail: source.detail)
    }
}

public enum AgentMeterPhoneSourceConfidence: String, Codable, Equatable, Sendable {
    case official
    case local
    case privateEndpoint = "private"
    case derived
    case unknown

    public init(_ confidence: AgentMeterSourceConfidence) {
        switch confidence {
        case .official:
            self = .official
        case .local:
            self = .local
        case .privateEndpoint:
            self = .privateEndpoint
        case .derived:
            self = .derived
        case .unknown:
            self = .unknown
        }
    }
}

public enum AgentMeterPhoneProviderStatus: String, Codable, Equatable, Sendable {
    case ok
    case stale
    case unavailable
    case unauthenticated
    case error

    public init(_ status: AgentMeterProviderStatus) {
        switch status {
        case .ok:
            self = .ok
        case .stale:
            self = .stale
        case .unavailable:
            self = .unavailable
        case .unauthenticated:
            self = .unauthenticated
        case .error:
            self = .error
        }
    }
}

public enum AgentMeterPhoneSnapshotExportError: Error, Equatable, Sendable {
    case sourceMissing(String)
    case sensitiveMaterialDetected
}

public enum AgentMeterPhoneSnapshotStoreError: Error, Equatable, Sendable {
    case sensitiveMaterialDetected
}

public enum AgentMeterPhoneSnapshotExporter {
    @discardableResult
    public static func export(
        sourceURL: URL = AgentMeterPhoneSnapshotStore.defaultURL(),
        destinationURL: URL)
        throws -> URL
    {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw AgentMeterPhoneSnapshotExportError.sourceMissing(sourceURL.path)
        }

        let data = try Data(contentsOf: sourceURL)
        guard !AgentMeterPhoneSnapshotStore.containsSensitiveMaterial(data) else {
            throw AgentMeterPhoneSnapshotExportError.sensitiveMaterialDetected
        }

        let snapshot = try AgentMeterPhoneSnapshotStore.decoder.decode(AgentMeterPhoneSnapshot.self, from: data)
        try AgentMeterPhoneSnapshotStore.save(snapshot, fileURL: destinationURL)
        return destinationURL
    }
}

public enum AgentMeterPhoneSnapshotStore {
    public static let filename = "agentmeter-phone-snapshot.json"

    public static func load(fileURL: URL = Self.defaultURL()) -> AgentMeterPhoneSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? self.decoder.decode(AgentMeterPhoneSnapshot.self, from: data)
    }

    public static func save(_ snapshot: AgentMeterPhoneSnapshot, fileURL: URL = Self.defaultURL()) throws {
        let directory = fileURL.deletingLastPathComponent()
        try AgentMeterFileSecurity.ensurePrivateDirectory(directory)
        let data = try self.encoder.encode(snapshot)
        guard !self.containsSensitiveMaterial(data) else {
            throw AgentMeterPhoneSnapshotStoreError.sensitiveMaterialDetected
        }
        try data.write(to: fileURL, options: [.atomic])
        try AgentMeterFileSecurity.applyPrivateFilePermissions(fileURL)
    }

    public static func defaultURL(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> URL
    {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("AgentMeter", isDirectory: true)
            .appendingPathComponent(self.filename, isDirectory: false)
    }

    public static func containsSensitiveMaterial(_ data: Data) -> Bool {
        // Non-failable decode is deliberate: the scan must inspect even malformed UTF-8 so
        // invalid bytes cannot smuggle secrets past the check. A failable init would fail open.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: data, as: UTF8.self).lowercased()
        let markers = [
            "apikey",
            "api_key",
            "bearer ",
            "cookie",
            "refresh_token",
            "access_token",
            "client_secret",
            "password",
            "sk-",
            "ghp_",
        ]
        return markers.contains { text.contains($0) }
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

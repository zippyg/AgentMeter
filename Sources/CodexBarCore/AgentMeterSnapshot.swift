import Foundation

public enum AgentMeterSourceConfidence: String, Codable, Equatable, Sendable {
    case official
    case local
    case privateEndpoint = "private"
    case derived
    case unknown
}

public struct AgentMeterSourceDescriptor: Codable, Equatable, Sendable {
    public let confidence: AgentMeterSourceConfidence
    public let label: String
    public let detail: String?

    public init(confidence: AgentMeterSourceConfidence, label: String, detail: String? = nil) {
        self.confidence = confidence
        self.label = label
        self.detail = detail
    }
}

public enum AgentMeterProviderStatus: String, Codable, Equatable, Sendable {
    case ok
    case stale
    case unavailable
    case unauthenticated
    case error
}

public struct AgentMeterSnapshotProducer: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public let version: String?
    public let build: String?

    public init(
        bundleIdentifier: String,
        displayName: String,
        version: String? = nil,
        build: String? = nil)
    {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.version = version
        self.build = build
    }

    public static func current(bundle: Bundle = .main) -> AgentMeterSnapshotProducer {
        let info = bundle.infoDictionary ?? [:]
        return AgentMeterSnapshotProducer(
            bundleIdentifier: bundle.bundleIdentifier ?? "com.zain.agentmeter.unknown",
            displayName: (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? "AgentMeter",
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String)
    }
}

public struct AgentMeterSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let snapshotSequence: Int
    public let generatedAt: Date
    public let producer: AgentMeterSnapshotProducer?
    public let providers: [AgentMeterProviderSnapshot]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        snapshotSequence: Int = 0,
        generatedAt: Date,
        producer: AgentMeterSnapshotProducer? = nil,
        providers: [AgentMeterProviderSnapshot])
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
        snapshotSequence: Int = 0,
        producer: AgentMeterSnapshotProducer? = nil,
        nextRefreshAt: Date? = nil)
    {
        self.init(
            snapshotSequence: snapshotSequence,
            generatedAt: widgetSnapshot.generatedAt,
            producer: producer,
            providers: widgetSnapshot.entries.map { entry in
                AgentMeterProviderSnapshot(
                    widgetEntry: entry,
                    metadata: metadata[entry.provider],
                    staleInterval: staleInterval,
                    nextRefreshAt: nextRefreshAt)
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
        self.providers = try container.decode([AgentMeterProviderSnapshot].self, forKey: .providers)
    }

    public func preservingPreviousProvidersOnTransientEmpty(
        previous: AgentMeterSnapshot?,
        nextRefreshAt: Date?,
        now: Date,
        reason: String = "No fresh provider snapshots were available during this refresh.")
        -> AgentMeterSnapshot
    {
        guard self.providers.isEmpty,
              let previous,
              !previous.providers.isEmpty
        else {
            return self
        }
        return AgentMeterSnapshot(
            schemaVersion: self.schemaVersion,
            snapshotSequence: self.snapshotSequence,
            generatedAt: self.generatedAt,
            producer: self.producer,
            providers: previous.providers.map {
                $0.withStatus(
                    .stale,
                    staleAfter: $0.staleAfter.map { min($0, now) } ?? now,
                    nextRefreshAt: nextRefreshAt,
                    lastError: reason)
            })
    }
}

public struct AgentMeterProviderSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let accountLabel: String?
    public let plan: String?
    public let windows: [AgentMeterUsageWindow]
    public let spend: AgentMeterSpendSummary?
    public let tokenUsage: AgentMeterTokenUsageSummary?
    public let creditsRemaining: Double?
    public let codeReviewRemainingPercent: Double?
    public let source: AgentMeterSourceDescriptor
    public let status: AgentMeterProviderStatus
    public let updatedAt: Date
    public let staleAfter: Date?
    public let nextRefreshAt: Date?
    public let lastError: String?

    public init(
        id: String,
        displayName: String,
        accountLabel: String? = nil,
        plan: String? = nil,
        windows: [AgentMeterUsageWindow],
        spend: AgentMeterSpendSummary? = nil,
        tokenUsage: AgentMeterTokenUsageSummary? = nil,
        creditsRemaining: Double? = nil,
        codeReviewRemainingPercent: Double? = nil,
        source: AgentMeterSourceDescriptor,
        status: AgentMeterProviderStatus,
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
        self.spend = spend
        self.tokenUsage = tokenUsage
        self.creditsRemaining = creditsRemaining
        self.codeReviewRemainingPercent = codeReviewRemainingPercent
        self.source = source
        self.status = status
        self.updatedAt = updatedAt
        self.staleAfter = staleAfter
        self.nextRefreshAt = nextRefreshAt
        self.lastError = lastError?.nonEmpty
    }

    public init(
        widgetEntry: WidgetSnapshot.ProviderEntry,
        metadata: ProviderMetadata?,
        staleInterval: TimeInterval = 15 * 60,
        nextRefreshAt: Date? = nil)
    {
        let windows = Self.windows(from: widgetEntry, metadata: metadata)
        self.init(
            id: widgetEntry.provider.rawValue,
            displayName: metadata?.displayName ?? widgetEntry.provider.rawValue,
            windows: windows,
            tokenUsage: widgetEntry.tokenUsage.map(AgentMeterTokenUsageSummary.init(widgetTokenUsage:)),
            creditsRemaining: widgetEntry.creditsRemaining,
            codeReviewRemainingPercent: widgetEntry.codeReviewRemainingPercent,
            source: AgentMeterSourceDescriptor(
                confidence: .derived,
                label: "AgentMeter snapshot",
                detail: "Derived from sanitized provider usage state."),
            status: windows.isEmpty ? .unavailable : .ok,
            updatedAt: widgetEntry.updatedAt,
            staleAfter: widgetEntry.updatedAt.addingTimeInterval(staleInterval),
            nextRefreshAt: nextRefreshAt)
    }

    public func withStatus(
        _ status: AgentMeterProviderStatus,
        updatedAt: Date? = nil,
        staleAfter: Date? = nil,
        nextRefreshAt: Date? = nil,
        lastError: String? = nil)
        -> AgentMeterProviderSnapshot
    {
        AgentMeterProviderSnapshot(
            id: self.id,
            displayName: self.displayName,
            accountLabel: self.accountLabel,
            plan: self.plan,
            windows: self.windows,
            spend: self.spend,
            tokenUsage: self.tokenUsage,
            creditsRemaining: self.creditsRemaining,
            codeReviewRemainingPercent: self.codeReviewRemainingPercent,
            source: self.source,
            status: status,
            updatedAt: updatedAt ?? self.updatedAt,
            staleAfter: staleAfter ?? self.staleAfter,
            nextRefreshAt: nextRefreshAt ?? self.nextRefreshAt,
            lastError: lastError ?? self.lastError)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case accountLabel
        case plan
        case windows
        case spend
        case tokenUsage
        case creditsRemaining
        case codeReviewRemainingPercent
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
        self.windows = try container.decode([AgentMeterUsageWindow].self, forKey: .windows)
        self.spend = try container.decodeIfPresent(AgentMeterSpendSummary.self, forKey: .spend)
        self.tokenUsage = try container.decodeIfPresent(AgentMeterTokenUsageSummary.self, forKey: .tokenUsage)
        self.creditsRemaining = try container.decodeIfPresent(Double.self, forKey: .creditsRemaining)
        self.codeReviewRemainingPercent = try container.decodeIfPresent(
            Double.self,
            forKey: .codeReviewRemainingPercent)
        self.source = try container.decode(AgentMeterSourceDescriptor.self, forKey: .source)
        self.status = try container.decodeIfPresent(AgentMeterProviderStatus.self, forKey: .status) ?? .ok
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.staleAfter = try container.decodeIfPresent(Date.self, forKey: .staleAfter)
        self.nextRefreshAt = try container.decodeIfPresent(Date.self, forKey: .nextRefreshAt)
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)?.nonEmpty
    }

    private static func windows(
        from entry: WidgetSnapshot.ProviderEntry,
        metadata: ProviderMetadata?) -> [AgentMeterUsageWindow]
    {
        var windows: [AgentMeterUsageWindow] = []
        if let primary = entry.primary {
            windows.append(AgentMeterUsageWindow(
                id: "session",
                title: metadata?.sessionLabel.nonEmpty ?? "Session",
                rateWindow: primary))
        }
        if let secondary = entry.secondary {
            windows.append(AgentMeterUsageWindow(
                id: "weekly",
                title: metadata?.weeklyLabel.nonEmpty ?? "Weekly",
                rateWindow: secondary))
        }
        if let tertiary = entry.tertiary {
            windows.append(AgentMeterUsageWindow(
                id: "tertiary",
                title: metadata?.opusLabel?.nonEmpty ?? "Tertiary",
                rateWindow: tertiary))
        }

        let existingIDs = Set(windows.map(\.id))
        for row in entry.usageRows ?? [] where !existingIDs.contains(row.id) {
            windows.append(AgentMeterUsageWindow(
                id: row.id,
                title: row.title,
                usedPercent: row.percentLeft.map { max(0, 100 - $0) },
                remainingPercent: row.percentLeft,
                resetsAt: nil,
                resetDescription: nil,
                windowMinutes: nil))
        }
        return windows
    }
}

public struct AgentMeterUsageWindow: Codable, Equatable, Sendable {
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
        self.usedPercent = usedPercent.map(Self.clampedPercent)
        self.remainingPercent = remainingPercent.map(Self.clampedPercent)
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.windowMinutes = windowMinutes
    }

    public init(id: String, title: String, rateWindow: RateWindow) {
        self.init(
            id: id,
            title: title,
            usedPercent: rateWindow.usedPercent,
            remainingPercent: rateWindow.remainingPercent,
            resetsAt: rateWindow.resetsAt,
            resetDescription: rateWindow.resetDescription,
            windowMinutes: rateWindow.windowMinutes)
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}

public struct AgentMeterSpendSummary: Codable, Equatable, Sendable {
    public let used: Double?
    public let limit: Double?
    public let remaining: Double?
    public let currencyCode: String
    public let period: String?
    public let resetsAt: Date?

    public init(
        used: Double?,
        limit: Double?,
        remaining: Double?,
        currencyCode: String = "USD",
        period: String? = nil,
        resetsAt: Date? = nil)
    {
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.currencyCode = currencyCode.nonEmpty?.uppercased() ?? "USD"
        self.period = period
        self.resetsAt = resetsAt
    }
}

public struct AgentMeterTokenUsageSummary: Codable, Equatable, Sendable {
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
        self.currencyCode = currencyCode.nonEmpty?.uppercased() ?? "USD"
        self.sessionLabel = sessionLabel.nonEmpty ?? "Today"
        self.last30DaysLabel = last30DaysLabel.nonEmpty ?? "30d"
    }

    public init(widgetTokenUsage: WidgetSnapshot.TokenUsageSummary) {
        self.init(
            sessionCostUSD: widgetTokenUsage.sessionCostUSD,
            sessionTokens: widgetTokenUsage.sessionTokens,
            last30DaysCostUSD: widgetTokenUsage.last30DaysCostUSD,
            last30DaysTokens: widgetTokenUsage.last30DaysTokens,
            currencyCode: widgetTokenUsage.currencyCode,
            sessionLabel: widgetTokenUsage.sessionLabel,
            last30DaysLabel: widgetTokenUsage.last30DaysLabel)
    }
}

public enum AgentMeterSnapshotStore {
    public static let filename = "agentmeter-summary.json"

    public static func load(fileURL: URL = Self.defaultURL()) -> AgentMeterSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? self.decoder.decode(AgentMeterSnapshot.self, from: data)
    }

    public static func save(
        _ snapshot: AgentMeterSnapshot,
        fileURL: URL = Self.defaultURL(),
        postNotification: (URL, AgentMeterSnapshot) -> Void = AgentMeterSnapshotNotification.post)
        throws
    {
        let directory = fileURL.deletingLastPathComponent()
        try AgentMeterFileSecurity.ensurePrivateDirectory(directory)
        let data = try self.encoder.encode(snapshot)
        guard !AgentMeterSnapshotSecurity.containsSensitiveMaterial(data) else {
            throw AgentMeterSnapshotStoreError.sensitiveMaterialDetected
        }
        try data.write(to: fileURL, options: [.atomic])
        try AgentMeterFileSecurity.applyPrivateFilePermissions(fileURL)
        postNotification(fileURL, snapshot)
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

public enum AgentMeterFileSecurity {
    public static func ensurePrivateDirectory(
        _ directory: URL,
        fileManager: FileManager = .default,
        repairExistingPermissions: Bool = true)
        throws
    {
        var isDirectory: ObjCBool = false
        let existed = fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        if existed, !isDirectory.boolValue {
            throw AgentMeterFileSecurityError.pathIsNotDirectory(directory.path)
        }
        if !existed {
            #if os(macOS) || os(Linux)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            #else
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            #endif
        }
        #if os(macOS) || os(Linux)
        if repairExistingPermissions {
            try fileManager.setAttributes([
                .posixPermissions: NSNumber(value: Int16(0o700)),
            ], ofItemAtPath: directory.path)
        }
        #endif
    }

    public static func applyPrivateFilePermissions(_ fileURL: URL, fileManager: FileManager = .default) throws {
        #if os(macOS) || os(Linux)
        try fileManager.setAttributes([
            .posixPermissions: NSNumber(value: Int16(0o600)),
        ], ofItemAtPath: fileURL.path)
        #endif
    }
}

public enum AgentMeterFileSecurityError: Error, Equatable, Sendable {
    case pathIsNotDirectory(String)
}

public enum AgentMeterSnapshotStoreError: Error, Equatable, Sendable {
    case sensitiveMaterialDetected
}

public enum AgentMeterSnapshotNotification {
    public static let name = AgentMeterIdentity.snapshotUpdatedNotification

    public static func userInfo(fileURL: URL, snapshot: AgentMeterSnapshot) -> [String: Any] {
        [
            "path": fileURL.path,
            "schemaVersion": snapshot.schemaVersion,
            "snapshotSequence": snapshot.snapshotSequence,
            "generatedAt": ISO8601DateFormatter().string(from: snapshot.generatedAt),
        ]
    }

    public static func post(fileURL: URL, snapshot: AgentMeterSnapshot) {
        #if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(self.name),
            object: nil,
            userInfo: self.userInfo(fileURL: fileURL, snapshot: snapshot),
            deliverImmediately: true)
        #endif
    }
}

public enum AgentMeterSnapshotSecurity {
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
}

public enum AgentMeterSnapshotSequenceStore {
    private static let key = "agentmeterSnapshotSequence"
    private static let lock = NSLock()

    public static func next(defaults: UserDefaults = .standard) -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        let next = defaults.integer(forKey: self.key) + 1
        defaults.set(next, forKey: self.key)
        return next
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

import Foundation

struct AgentMeterPhoneSnapshot: Codable, Equatable, Sendable {
    static let primaryProviderIDs: Set<String> = ["claude", "codex"]
    private static let primaryProviderOrder = ["claude", "codex"]

    var schemaVersion: Int
    var snapshotSequence: Int
    var generatedAt: Date
    var providers: [AgentMeterPhoneProvider]

    var codex: AgentMeterPhoneProvider? {
        self.providers.first { $0.id == "codex" }
    }

    var claude: AgentMeterPhoneProvider? {
        self.providers.first { $0.usageProviderID == "claude" && $0.isActiveCLI == true }
            ?? self.providers.first { $0.usageProviderID == "claude" }
    }

    var isStale: Bool {
        self.isStale(reference: Date())
    }

    var isEmpty: Bool {
        self.providers.isEmpty
    }

    func isStale(reference: Date) -> Bool {
        guard !self.providers.isEmpty else { return false }
        return self.providers.allSatisfy { $0.isStale(reference: reference) }
    }

    func hasStaleProvider(reference: Date) -> Bool {
        self.providers.contains { $0.isStale(reference: reference) }
    }

    var isSampleData: Bool {
        guard !self.providers.isEmpty else { return false }
        return self.providers.allSatisfy { provider in
            provider.source.label == "Sample data" || provider.status == .unavailable
        }
    }

    func primaryProjection(providerIDs: Set<String> = Self.primaryProviderIDs) -> AgentMeterPhoneSnapshot {
        let orderedProviders: [AgentMeterPhoneProvider]
        if providerIDs == Self.primaryProviderIDs {
            let providersByID = Dictionary(grouping: self.providers.filter { providerIDs.contains($0.usageProviderID) },
                                           by: \.usageProviderID)
            orderedProviders = Self.primaryProviderOrder.flatMap { providersByID[$0] ?? [] }
        } else {
            orderedProviders = self.providers.filter { providerIDs.contains($0.usageProviderID) }
        }

        return AgentMeterPhoneSnapshot(
            schemaVersion: self.schemaVersion,
            snapshotSequence: self.snapshotSequence,
            generatedAt: self.generatedAt,
            providers: orderedProviders)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case snapshotSequence
        case generatedAt
        case providers
    }

    init(
        schemaVersion: Int = 1,
        snapshotSequence: Int = 0,
        generatedAt: Date,
        providers: [AgentMeterPhoneProvider])
    {
        self.schemaVersion = schemaVersion
        self.snapshotSequence = snapshotSequence
        self.generatedAt = generatedAt
        self.providers = providers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.snapshotSequence = try container.decodeIfPresent(Int.self, forKey: .snapshotSequence) ?? 0
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.providers = try container.decode([AgentMeterPhoneProvider].self, forKey: .providers)
    }
}

struct AgentMeterPhoneProvider: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var providerID: String?
    var accountID: String?
    var isActiveCLI: Bool?
    var spend: AgentMeterSpendSummary?
    var creditsUsed: Double?
    var creditsRemaining: Double?
    var accountLabel: String?
    var plan: String?
    var windows: [AgentMeterPhoneUsageWindow]
    var tokenUsage: AgentMeterPhoneTokenUsage?
    var dailyUsage: [AgentMeterPhoneDailyUsagePoint]
    var source: AgentMeterPhoneSource
    var status: AgentMeterPhoneProviderStatus
    var updatedAt: Date
    var staleAfter: Date?
    var nextRefreshAt: Date?
    var lastError: String?

    init(
        id: String,
        displayName: String,
        providerID: String? = nil,
        accountID: String? = nil,
        isActiveCLI: Bool? = nil,
        spend: AgentMeterSpendSummary? = nil,
        creditsUsed: Double? = nil,
        creditsRemaining: Double? = nil,
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
        self.providerID = providerID
        self.accountID = accountID
        self.isActiveCLI = isActiveCLI
        self.spend = spend
        self.creditsUsed = creditsUsed
        self.creditsRemaining = creditsRemaining
        self.accountLabel = accountLabel
        self.plan = plan
        self.windows = Self.normalizedWindows(windows, providerID: providerID ?? id)
        self.tokenUsage = tokenUsage
        self.dailyUsage = dailyUsage
        self.source = source
        self.status = status
        self.updatedAt = updatedAt
        self.staleAfter = staleAfter
        self.nextRefreshAt = nextRefreshAt
        self.lastError = lastError
    }

    var usageProviderID: String { self.providerID ?? self.id }

    var accountDisplayLabel: String? {
        guard let accountLabel else { return nil }
        return accountLabel + (self.isActiveCLI == true ? " · CLI active" : "")
    }

    var primaryWindow: AgentMeterPhoneUsageWindow? {
        self.windows.first { $0.id == "session" } ?? (self.usesCanonicalQuotaWindowIDs ? nil : self.windows.first)
    }

    var weeklyWindow: AgentMeterPhoneUsageWindow? {
        self.windows.first { $0.id == "weekly" } ??
            (self.usesCanonicalQuotaWindowIDs ? nil : self.windows.dropFirst().first)
    }

    func window(id: String) -> AgentMeterPhoneUsageWindow? {
        self.windows.first { $0.id == id }
    }

    func isStale(reference: Date) -> Bool {
        self.status == .stale || self.staleAfter.map { $0 <= reference } ?? false
    }

    func displayStatus(reference: Date) -> AgentMeterPhoneProviderStatus {
        if self.status == .ok, self.isStale(reference: reference) {
            return .stale
        }
        return self.status
    }

    private var usesCanonicalQuotaWindowIDs: Bool {
        self.usageProviderID == "claude" || self.usageProviderID == "codex"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case providerID
        case accountID
        case isActiveCLI
        case spend
        case creditsUsed
        case creditsRemaining
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        self.accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        self.isActiveCLI = try container.decodeIfPresent(Bool.self, forKey: .isActiveCLI)
        self.spend = try container.decodeIfPresent(AgentMeterSpendSummary.self, forKey: .spend)
        self.creditsUsed = try container.decodeIfPresent(Double.self, forKey: .creditsUsed)
        self.creditsRemaining = try container.decodeIfPresent(Double.self, forKey: .creditsRemaining)
        self.accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel)
        self.plan = try container.decodeIfPresent(String.self, forKey: .plan)
        self.windows = Self.normalizedWindows(
            try container.decode([AgentMeterPhoneUsageWindow].self, forKey: .windows),
            providerID: self.providerID ?? self.id)
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

    private static func normalizedWindows(
        _ windows: [AgentMeterPhoneUsageWindow],
        providerID: String)
        -> [AgentMeterPhoneUsageWindow]
    {
        guard providerID == "claude" || providerID == "codex" else { return windows }

        var normalized: [AgentMeterPhoneUsageWindow] = []
        var indexByID: [String: Int] = [:]
        for original in windows {
            var window = original
            window.id = switch original.id {
            case "primary": "session"
            case "secondary": "weekly"
            default: original.id
            }

            if let index = indexByID[window.id] {
                if original.id == window.id {
                    normalized[index] = window
                }
                continue
            }
            indexByID[window.id] = normalized.count
            normalized.append(window)
        }
        return normalized
    }
}

struct AgentMeterPhoneUsageWindow: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var usedPercent: Double?
    var remainingPercent: Double?
    var resetsAt: Date?
    var resetDescription: String?
    var windowMinutes: Int?
}

struct AgentMeterPhoneTokenUsage: Codable, Equatable, Sendable {
    var sessionCostUSD: Double?
    var sessionTokens: Int?
    var last30DaysCostUSD: Double?
    var last30DaysTokens: Int?
    var currencyCode: String
    var sessionLabel: String
    var last30DaysLabel: String
}

struct AgentMeterPhoneDailyUsagePoint: Codable, Equatable, Sendable {
    var dayKey: String
    var totalTokens: Int?
    var costUSD: Double?
}

struct AgentMeterPhoneSource: Codable, Equatable, Sendable {
    var confidence: AgentMeterPhoneSourceConfidence
    var label: String
    var detail: String?
}

enum AgentMeterPhoneSourceConfidence: String, Codable, Equatable, Sendable {
    case official
    case local
    case `private`
    case derived
    case unknown
}

enum AgentMeterPhoneProviderStatus: String, Codable, Equatable, Sendable {
    case ok
    case stale
    case unavailable
    case unauthenticated
    case error
}

enum AgentMeterPhoneSettings {
    static let appearanceKey = "agentmeter.appearance"
    static let usageRangeKey = "agentmeter.usageRange"

    static var sharedDefaults: UserDefaults? {
        self.sharedDefaults()
    }

    static func sharedDefaults(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> UserDefaults? {
        guard let identifier = Self.configuredAppGroupIdentifier(infoDictionary: infoDictionary) else {
            return nil
        }
        return UserDefaults(suiteName: identifier)
    }

    static func configuredAppGroupIdentifier(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> String? {
        AgentMeterPhoneSnapshotStore.configuredAppGroupIdentifier(infoDictionary: infoDictionary)
    }
}

struct AgentMeterSpendSummary: Codable, Equatable, Sendable {
    var used: Double?
    var limit: Double?
    var remaining: Double?
    var currencyCode: String
    var period: String?
    var resetsAt: Date?
}

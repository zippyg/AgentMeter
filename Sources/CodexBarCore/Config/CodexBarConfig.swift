import Foundation

public struct CodexBarConfig: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var providers: [ProviderConfig]

    public init(version: Int = Self.currentVersion, providers: [ProviderConfig]) {
        self.version = version
        self.providers = providers
    }

    public static func makeDefault(
        metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata) -> CodexBarConfig
    {
        let providers = UsageProvider.allCases.map { provider in
            ProviderConfig(
                id: provider,
                enabled: metadata[provider]?.defaultEnabled)
        }
        return CodexBarConfig(version: Self.currentVersion, providers: providers)
    }

    public func normalized(
        metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata) -> CodexBarConfig
    {
        var seen: Set<UsageProvider> = []
        var normalized: [ProviderConfig] = []
        normalized.reserveCapacity(max(self.providers.count, UsageProvider.allCases.count))

        for provider in self.providers {
            guard !seen.contains(provider.id) else { continue }
            seen.insert(provider.id)
            normalized.append(provider)
        }

        for provider in UsageProvider.allCases where !seen.contains(provider) {
            normalized.append(ProviderConfig(
                id: provider,
                enabled: metadata[provider]?.defaultEnabled))
        }

        return CodexBarConfig(
            version: Self.currentVersion,
            providers: normalized)
    }

    public func orderedProviders() -> [UsageProvider] {
        self.providers.map(\.id)
    }

    public func enabledProviders(
        metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata) -> [UsageProvider]
    {
        self.providers.compactMap { config in
            let enabled = config.enabled ?? metadata[config.id]?.defaultEnabled ?? false
            return enabled ? config.id : nil
        }
    }

    public func providerConfig(for id: UsageProvider) -> ProviderConfig? {
        self.providers.first(where: { $0.id == id })
    }

    public mutating func setProviderConfig(_ config: ProviderConfig) {
        if let index = self.providers.firstIndex(where: { $0.id == config.id }) {
            self.providers[index] = config
        } else {
            self.providers.append(config)
        }
    }
}

public struct ProviderConfig: Codable, Sendable, Identifiable {
    public let id: UsageProvider
    public var enabled: Bool?
    public var source: ProviderSourceMode?
    public var extrasEnabled: Bool?
    public var apiKey: String?
    public var secretKey: String?
    public var cookieHeader: String?
    public var credentialReferences: ProviderCredentialReferences?
    public var cookieSource: ProviderCookieSource?
    public var region: String?
    public var workspaceID: String?
    public var enterpriseHost: String?
    public var tokenAccounts: ProviderTokenAccountData?
    public var codexActiveSource: CodexActiveSource?
    public var quotaWarnings: QuotaWarningConfig?
    public var kiloKnownOrganizations: [KiloOrganization]?
    public var kiloEnabledOrganizationIDs: [String]?
    public var awsProfile: String?
    public var awsAuthMode: String?

    public init(
        id: UsageProvider,
        enabled: Bool? = nil,
        source: ProviderSourceMode? = nil,
        extrasEnabled: Bool? = nil,
        apiKey: String? = nil,
        secretKey: String? = nil,
        cookieHeader: String? = nil,
        credentialReferences: ProviderCredentialReferences? = nil,
        cookieSource: ProviderCookieSource? = nil,
        region: String? = nil,
        workspaceID: String? = nil,
        enterpriseHost: String? = nil,
        tokenAccounts: ProviderTokenAccountData? = nil,
        codexActiveSource: CodexActiveSource? = nil,
        quotaWarnings: QuotaWarningConfig? = nil,
        kiloKnownOrganizations: [KiloOrganization]? = nil,
        kiloEnabledOrganizationIDs: [String]? = nil,
        awsProfile: String? = nil,
        awsAuthMode: String? = nil)
    {
        self.id = id
        self.enabled = enabled
        self.source = source
        self.extrasEnabled = extrasEnabled
        self.apiKey = apiKey
        self.secretKey = secretKey
        self.cookieHeader = cookieHeader
        self.credentialReferences = credentialReferences
        self.cookieSource = cookieSource
        self.region = region
        self.workspaceID = workspaceID
        self.enterpriseHost = enterpriseHost
        self.tokenAccounts = tokenAccounts
        self.codexActiveSource = codexActiveSource
        self.quotaWarnings = quotaWarnings
        self.kiloKnownOrganizations = kiloKnownOrganizations
        self.kiloEnabledOrganizationIDs = kiloEnabledOrganizationIDs
        self.awsProfile = awsProfile
        self.awsAuthMode = awsAuthMode
    }

    public var inlineAPIKey: String? {
        Self.clean(self.apiKey)
    }

    public var inlineSecretKey: String? {
        Self.clean(self.secretKey)
    }

    public var inlineCookieHeader: String? {
        Self.clean(self.cookieHeader)
    }

    public var sanitizedAPIKey: String? {
        self.inlineAPIKey ?? Self.loadCredential(self.credentialReferences?.apiKey)
    }

    public var sanitizedSecretKey: String? {
        self.inlineSecretKey ?? Self.loadCredential(self.credentialReferences?.secretKey)
    }

    public var sanitizedCookieHeader: String? {
        self.inlineCookieHeader ?? Self.loadCredential(self.credentialReferences?.cookieHeader)
    }

    public var sanitizedRegion: String? {
        Self.clean(self.region)
    }

    public var sanitizedWorkspaceID: String? {
        Self.clean(self.workspaceID)
    }

    public var sanitizedEnterpriseHost: String? {
        Self.clean(self.enterpriseHost)
    }

    public var sanitizedAWSProfile: String? {
        Self.clean(self.awsProfile)
    }

    public var sanitizedAWSAuthMode: String? {
        Self.clean(self.awsAuthMode)
    }

    public var containsInlineSecretMaterial: Bool {
        self.inlineAPIKey != nil ||
            self.inlineSecretKey != nil ||
            self.inlineCookieHeader != nil ||
            (self.tokenAccounts?.accounts.contains { $0.containsInlineSecretMaterial } ?? false)
    }

    public func removingInlineSecretMaterial() -> ProviderConfig {
        let tokenAccounts = self.tokenAccounts.map { data in
            ProviderTokenAccountData(
                version: data.version,
                accounts: data.accounts.map {
                    $0.replacingSecretMaterial(token: "", credentialReference: $0.credentialReference)
                },
                activeIndex: data.activeIndex)
        }
        return ProviderConfig(
            id: self.id,
            enabled: self.enabled,
            source: self.source,
            extrasEnabled: self.extrasEnabled,
            credentialReferences: self.credentialReferences,
            cookieSource: self.cookieSource,
            region: self.region,
            workspaceID: self.workspaceID,
            enterpriseHost: self.enterpriseHost,
            tokenAccounts: tokenAccounts,
            codexActiveSource: self.codexActiveSource,
            quotaWarnings: self.quotaWarnings,
            kiloKnownOrganizations: self.kiloKnownOrganizations,
            kiloEnabledOrganizationIDs: self.kiloEnabledOrganizationIDs,
            awsProfile: self.awsProfile,
            awsAuthMode: self.awsAuthMode)
    }

    private static func clean(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func loadCredential(_ reference: AgentMeterCredentialReference?) -> String? {
        guard let reference else { return nil }
        return try? AgentMeterKeychainCredentialStore().load(reference: reference)
    }
}

public enum QuotaWarningWindow: String, Codable, Sendable, CaseIterable {
    case session
    case weekly

    public var displayName: String {
        switch self {
        case .session:
            "session"
        case .weekly:
            "weekly"
        }
    }
}

public struct QuotaWarningWindowConfig: Codable, Sendable, Equatable {
    public var thresholds: [Int]?
    public var enabled: Bool?

    public init(thresholds: [Int]? = nil, enabled: Bool? = nil) {
        self.thresholds = thresholds.map(QuotaWarningThresholds.sanitized)
        self.enabled = enabled
    }

    public var hasOverride: Bool {
        self.thresholds != nil || self.enabled != nil
    }

    public func isEnabled(global: Bool) -> Bool {
        self.enabled ?? (self.thresholds != nil ? true : global)
    }
}

public struct QuotaWarningConfig: Codable, Sendable, Equatable {
    public var session: QuotaWarningWindowConfig?
    public var weekly: QuotaWarningWindowConfig?

    public init(
        session: QuotaWarningWindowConfig? = nil,
        weekly: QuotaWarningWindowConfig? = nil)
    {
        self.session = session
        self.weekly = weekly
    }

    public func thresholds(for window: QuotaWarningWindow, global: [Int]) -> [Int] {
        switch window {
        case .session:
            QuotaWarningThresholds.sanitized(self.session?.thresholds ?? global)
        case .weekly:
            QuotaWarningThresholds.sanitized(self.weekly?.thresholds ?? global)
        }
    }

    public func isEnabled(for window: QuotaWarningWindow, global: Bool) -> Bool {
        switch window {
        case .session:
            self.session?.isEnabled(global: global) ?? global
        case .weekly:
            self.weekly?.isEnabled(global: global) ?? global
        }
    }

    public func hasOverride(for window: QuotaWarningWindow) -> Bool {
        switch window {
        case .session:
            self.session?.hasOverride ?? false
        case .weekly:
            self.weekly?.hasOverride ?? false
        }
    }

    public var isEmpty: Bool {
        self.session?.hasOverride != true && self.weekly?.hasOverride != true
    }
}

public enum QuotaWarningThresholds {
    public static let defaults = [5] // warn once at 95% used (5% remaining)
    public static let allowedRange = 0...99

    public static func sanitized(_ raw: [Int]) -> [Int] {
        guard !raw.isEmpty else { return self.defaults }

        let unique = Set(raw.map(self.clamped))
        let sorted = unique.sorted(by: >)
        return sorted.isEmpty ? self.defaults : sorted
    }

    public static func active(_ raw: [Int]) -> [Int] {
        self.sanitized(raw).filter { $0 > 0 }
    }

    public static func clamped(_ value: Int) -> Int {
        min(max(value, self.allowedRange.lowerBound), self.allowedRange.upperBound)
    }
}

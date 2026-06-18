import Foundation
#if canImport(Security)
import Security
#endif

public struct AgentMeterCredentialReference: Codable, Equatable, Hashable, Sendable {
    public let service: String
    public let account: String
    public let label: String?

    public init(
        service: String = AgentMeterKeychainCredentialStore.serviceName,
        account: String,
        label: String? = nil)
    {
        self.service = service
        self.account = account
        self.label = label
    }
}

public enum AgentMeterCredentialField: String, Codable, Sendable {
    case apiKey
    case secretKey
    case cookieHeader
    case tokenAccount
}

public struct ProviderCredentialReferences: Codable, Equatable, Sendable {
    public var apiKey: AgentMeterCredentialReference?
    public var secretKey: AgentMeterCredentialReference?
    public var cookieHeader: AgentMeterCredentialReference?
    public var tokenAccounts: [String: AgentMeterCredentialReference]?

    public init(
        apiKey: AgentMeterCredentialReference? = nil,
        secretKey: AgentMeterCredentialReference? = nil,
        cookieHeader: AgentMeterCredentialReference? = nil,
        tokenAccounts: [String: AgentMeterCredentialReference]? = nil)
    {
        self.apiKey = apiKey
        self.secretKey = secretKey
        self.cookieHeader = cookieHeader
        self.tokenAccounts = tokenAccounts
    }

    public var isEmpty: Bool {
        self.apiKey == nil &&
            self.secretKey == nil &&
            self.cookieHeader == nil &&
            (self.tokenAccounts?.isEmpty ?? true)
    }
}

public struct AgentMeterConfigSecretMigrationResult: Sendable {
    public let config: CodexBarConfig
    public let migratedSecretCount: Int
    public let failedSecretCount: Int

    public init(config: CodexBarConfig, migratedSecretCount: Int, failedSecretCount: Int) {
        self.config = config
        self.migratedSecretCount = migratedSecretCount
        self.failedSecretCount = failedSecretCount
    }

    public var changed: Bool {
        self.migratedSecretCount > 0
    }
}

public enum AgentMeterCredentialStoreError: LocalizedError, Equatable {
    case serviceMismatch(expected: String, actual: String)
    case storeFailed(AgentMeterCredentialReference)
    case loadTemporarilyUnavailable(AgentMeterCredentialReference)
    case invalidPayload(AgentMeterCredentialReference)
    case deleteFailed(AgentMeterCredentialReference)

    public var errorDescription: String? {
        switch self {
        case let .serviceMismatch(expected, actual):
            "Credential service mismatch. Expected \(expected), got \(actual)."
        case let .storeFailed(reference):
            "Failed to store AgentMeter credential reference \(reference.account)."
        case let .loadTemporarilyUnavailable(reference):
            "AgentMeter credential reference \(reference.account) is temporarily unavailable."
        case let .invalidPayload(reference):
            "AgentMeter credential reference \(reference.account) contains an invalid payload."
        case let .deleteFailed(reference):
            "Failed to delete AgentMeter credential reference \(reference.account)."
        }
    }
}

public protocol AgentMeterCredentialStoring: Sendable {
    func store(_ secret: String, for reference: AgentMeterCredentialReference) throws
    func load(reference: AgentMeterCredentialReference) throws -> String?
    func delete(reference: AgentMeterCredentialReference) throws
}

public enum AgentMeterConfigSecretMigrator {
    public static func migrateInlineSecrets(
        in config: CodexBarConfig,
        store: any AgentMeterCredentialStoring = AgentMeterKeychainCredentialStore())
        -> AgentMeterConfigSecretMigrationResult
    {
        var migrated = config
        var run = MigrationRun(store: store)

        for index in migrated.providers.indices {
            var entry = migrated.providers[index]
            var references = entry.credentialReferences ?? ProviderCredentialReferences()

            Self.migrate(
                entry.inlineAPIKey,
                provider: entry.id,
                field: .apiKey,
                existing: &references.apiKey,
                run: &run)
                .map { entry.apiKey = $0 }
            Self.migrate(
                entry.inlineSecretKey,
                provider: entry.id,
                field: .secretKey,
                existing: &references.secretKey,
                run: &run)
                .map { entry.secretKey = $0 }
            Self.migrate(
                entry.inlineCookieHeader,
                provider: entry.id,
                field: .cookieHeader,
                existing: &references.cookieHeader,
                run: &run)
                .map { entry.cookieHeader = $0 }

            if let tokenAccounts = entry.tokenAccounts {
                var accountReferences = references.tokenAccounts ?? [:]
                let accounts = tokenAccounts.accounts.map { account in
                    Self.migratedAccount(
                        account,
                        provider: entry.id,
                        references: &accountReferences,
                        run: &run)
                }
                references.tokenAccounts = accountReferences.isEmpty ? nil : accountReferences
                entry.tokenAccounts = ProviderTokenAccountData(
                    version: tokenAccounts.version,
                    accounts: accounts,
                    activeIndex: tokenAccounts.activeIndex)
            }

            entry.credentialReferences = references.isEmpty ? nil : references
            migrated.providers[index] = entry
        }

        return AgentMeterConfigSecretMigrationResult(
            config: migrated,
            migratedSecretCount: run.migratedCount,
            failedSecretCount: run.failedCount)
    }

    private struct MigrationRun {
        let store: any AgentMeterCredentialStoring
        var migratedCount = 0
        var failedCount = 0

        mutating func store(_ value: String, for reference: AgentMeterCredentialReference) -> Bool {
            do {
                try self.store.store(value, for: reference)
                self.migratedCount += 1
                return true
            } catch {
                self.failedCount += 1
                return false
            }
        }
    }

    private static func migrate(
        _ value: String?,
        provider: UsageProvider,
        field: AgentMeterCredentialField,
        existing: inout AgentMeterCredentialReference?,
        run: inout MigrationRun)
        -> String??
    {
        guard let value else { return nil }
        let reference = Self.validReference(existing)
            ?? Self.reference(provider: provider, field: field)
        if run.store(value, for: reference) {
            existing = reference
            return .some(nil)
        }
        return nil
    }

    private static func migratedAccount(
        _ account: ProviderTokenAccount,
        provider: UsageProvider,
        references: inout [String: AgentMeterCredentialReference],
        run: inout MigrationRun)
        -> ProviderTokenAccount
    {
        guard let token = account.inlineTokenForMigration else { return account }
        let key = account.id.uuidString
        let reference = Self.validReference(account.credentialReference)
            ?? Self.validReference(references[key])
            ?? Self.reference(provider: provider, field: .tokenAccount, accountID: account.id, label: account.label)
        if run.store(token, for: reference) {
            references[key] = reference
            return account.replacingSecretMaterial(token: "", credentialReference: reference)
        }
        return account
    }

    private static func validReference(_ reference: AgentMeterCredentialReference?) -> AgentMeterCredentialReference? {
        guard let reference, reference.service == AgentMeterKeychainCredentialStore.serviceName else { return nil }
        return reference
    }

    private static func reference(
        provider: UsageProvider,
        field: AgentMeterCredentialField,
        accountID: UUID? = nil,
        label: String? = nil) -> AgentMeterCredentialReference
    {
        let suffix = accountID.map { ".\($0.uuidString)" } ?? ""
        let account = "\(provider.rawValue).\(field.rawValue)\(suffix)"
        let referenceLabel = label.map { "\(provider.rawValue) \($0)" } ?? "\(provider.rawValue) \(field.rawValue)"
        return AgentMeterCredentialReference(account: account, label: referenceLabel)
    }
}

public struct AgentMeterKeychainCredentialStore: AgentMeterCredentialStoring {
    public static let serviceName = AgentMeterIdentity.keychainService

    private struct SecretEnvelope: Codable, Equatable {
        let secret: String
    }

    public init() {}

    public func store(_ secret: String, for reference: AgentMeterCredentialReference) throws {
        try self.validate(reference)
        let key = Self.key(for: reference)
        let stored = KeychainCacheStore.withServiceOverride(Self.serviceName) {
            KeychainCacheStore.storeResult(key: key, entry: SecretEnvelope(secret: secret))
        }
        if !stored {
            throw AgentMeterCredentialStoreError.storeFailed(reference)
        }
    }

    public func load(reference: AgentMeterCredentialReference) throws -> String? {
        try self.validate(reference)
        let key = Self.key(for: reference)
        let result: KeychainCacheStore.LoadResult<SecretEnvelope> = KeychainCacheStore.withServiceOverride(
            Self.serviceName)
        {
            KeychainCacheStore.load(key: key, as: SecretEnvelope.self)
        }
        switch result {
        case let .found(envelope):
            return envelope.secret
        case .missing:
            return nil
        case .temporarilyUnavailable:
            throw AgentMeterCredentialStoreError.loadTemporarilyUnavailable(reference)
        case .invalid:
            throw AgentMeterCredentialStoreError.invalidPayload(reference)
        }
    }

    public func delete(reference: AgentMeterCredentialReference) throws {
        try self.validate(reference)
        let key = Self.key(for: reference)
        let result = KeychainCacheStore.withServiceOverride(Self.serviceName) {
            KeychainCacheStore.clearResult(key: key)
        }
        switch result {
        case .removed, .missing:
            return
        case .failed:
            throw AgentMeterCredentialStoreError.deleteFailed(reference)
        }
    }

    private func validate(_ reference: AgentMeterCredentialReference) throws {
        guard reference.service == Self.serviceName else {
            throw AgentMeterCredentialStoreError.serviceMismatch(
                expected: Self.serviceName,
                actual: reference.service)
        }
    }

    private static func key(for reference: AgentMeterCredentialReference) -> KeychainCacheStore.Key {
        KeychainCacheStore.Key(category: "credential", identifier: reference.account)
    }
}

public enum AgentMeterBridgeTokenStore {
    public static let account = "bridge.readToken"
    public static let serviceType = "_agentmeter._tcp"
    public static let deviceQueryItemName = "device"
    public static let deviceHeader = "x-agentmeter-bridge-device"

    private static let pairedDeviceIDsKey = "agentmeter.bridge.pairedDeviceIDs"
    private static let deviceAccountPrefix = "bridge.device."
    private static let deviceAccountSuffix = ".readToken"
    private static let tokenByteCount = 32

    public struct PairingSecret: Equatable, Sendable {
        public let deviceID: String
        public let token: String

        public init(deviceID: String, token: String) {
            self.deviceID = deviceID
            self.token = token
        }
    }

    public static func loadOrCreate(store: any AgentMeterCredentialStoring = AgentMeterKeychainCredentialStore())
        -> String?
    {
        let reference = Self.legacyReference()
        if let existing = try? store.load(reference: reference), Self.isValidToken(existing) {
            return existing
        }
        let token = Self.makeToken()
        do {
            try store.store(token, for: reference)
            return token
        } catch {
            return nil
        }
    }

    public static func createPairingSecret(
        defaults: UserDefaults = .standard,
        store: any AgentMeterCredentialStoring = AgentMeterKeychainCredentialStore())
        -> PairingSecret?
    {
        self.createDeviceSecret(defaults: defaults, store: store)
    }

    public static func createDeviceSecret(
        deviceID rawDeviceID: String? = nil,
        defaults: UserDefaults = .standard,
        store: any AgentMeterCredentialStoring = AgentMeterKeychainCredentialStore())
        -> PairingSecret?
    {
        let deviceID = rawDeviceID.flatMap(Self.normalizedDeviceID) ?? UUID().uuidString.lowercased()
        let token = Self.makeToken()
        do {
            try store.store(token, for: Self.deviceReference(deviceID: deviceID))
            var deviceIDs = Self.pairedDeviceIDs(defaults: defaults)
            deviceIDs.insert(deviceID)
            Self.savePairedDeviceIDs(deviceIDs, defaults: defaults)
            return PairingSecret(deviceID: deviceID, token: token)
        } catch {
            return nil
        }
    }

    public static func tokenForRequest(
        deviceID rawDeviceID: String?,
        defaults: UserDefaults = .standard,
        store: any AgentMeterCredentialStoring = AgentMeterKeychainCredentialStore())
        -> String?
    {
        guard let rawDeviceID,
              !rawDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return self.loadOrCreate(store: store)
        }
        guard let deviceID = Self.normalizedDeviceID(rawDeviceID),
              Self.pairedDeviceIDs(defaults: defaults).contains(deviceID),
              let token = try? store.load(reference: Self.deviceReference(deviceID: deviceID)),
              Self.isValidToken(token)
        else {
            return nil
        }
        return token
    }

    @discardableResult
    public static func revokeAllDevices(
        defaults: UserDefaults = .standard,
        store: any AgentMeterCredentialStoring = AgentMeterKeychainCredentialStore())
        -> Int
    {
        let legacyReference = Self.legacyReference()
        let legacyToken = try? store.load(reference: legacyReference)
        try? store.delete(reference: legacyReference)
        let deviceIDs = Self.pairedDeviceIDs(defaults: defaults)
        for deviceID in deviceIDs {
            try? store.delete(reference: Self.deviceReference(deviceID: deviceID))
        }
        Self.savePairedDeviceIDs([], defaults: defaults)
        return deviceIDs.count + ((legacyToken.map(Self.isValidToken) ?? false) ? 1 : 0)
    }

    public static func pairingURL(
        serviceName: String,
        token: String,
        deviceID: String? = nil,
        directHost: String? = nil,
        directPort: UInt16? = nil)
        -> URL?
    {
        var components = URLComponents()
        components.scheme = "agentmeter"
        components.host = "pair"
        var queryItems = [
            URLQueryItem(name: "service", value: serviceName),
            URLQueryItem(name: "type", value: Self.serviceType),
            URLQueryItem(name: "token", value: token),
        ]
        if let deviceID = deviceID.flatMap(Self.normalizedDeviceID) {
            queryItems.append(URLQueryItem(name: Self.deviceQueryItemName, value: deviceID))
        }
        if let directHost,
           !directHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let directPort
        {
            queryItems.append(URLQueryItem(name: "host", value: directHost))
            queryItems.append(URLQueryItem(name: "port", value: "\(directPort)"))
        }
        components.queryItems = queryItems
        return components.url
    }

    public static func serviceName(hostName: String = ProcessInfo.processInfo.hostName) -> String {
        let trimmed = hostName
            .replacingOccurrences(of: ".local", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "AgentMeter Mac" : "AgentMeter \(trimmed)"
    }

    private static func pairedDeviceIDs(defaults: UserDefaults) -> Set<String> {
        let raw = defaults.stringArray(forKey: Self.pairedDeviceIDsKey) ?? []
        return Set(raw.compactMap(Self.normalizedDeviceID))
    }

    private static func savePairedDeviceIDs(_ deviceIDs: Set<String>, defaults: UserDefaults) {
        defaults.set(deviceIDs.sorted(), forKey: self.pairedDeviceIDsKey)
    }

    private static func legacyReference() -> AgentMeterCredentialReference {
        AgentMeterCredentialReference(account: self.account, label: "AgentMeter iPhone bridge")
    }

    private static func deviceReference(deviceID: String) -> AgentMeterCredentialReference {
        AgentMeterCredentialReference(
            account: "\(self.deviceAccountPrefix)\(deviceID)\(self.deviceAccountSuffix)",
            label: "AgentMeter bridge device \(deviceID)")
    }

    private static func normalizedDeviceID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count >= 16, value.count <= 64 else { return nil }
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return value
    }

    private static func isValidToken(_ token: String) -> Bool {
        token.count >= 32 && token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func makeToken() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: Self.tokenByteCount)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return String(bytes.map { alphabet[Int($0) % alphabet.count] })
        }
        #endif
        var generator = SystemRandomNumberGenerator()
        return String((0..<Self.tokenByteCount).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

import CodexBarCore
import Foundation

struct AgentMeterLaunchMode: Equatable {
    static let safeLaunchKey = "AGENTMETER_SAFE_LAUNCH"
    static let disableProviderProbesKey = "AGENTMETER_DISABLE_PROVIDER_PROBES"
    static let disableSecretMigrationKey = "AGENTMETER_DISABLE_SECRET_MIGRATION"
    static let enableSecretMigrationKey = "AGENTMETER_ENABLE_SECRET_MIGRATION"
    static let disableStatusItemAutosaveKey = "AGENTMETER_DISABLE_STATUS_ITEM_AUTOSAVE"
    static let enableStatusItemAutosaveKey = "AGENTMETER_ENABLE_STATUS_ITEM_AUTOSAVE"

    let safeLaunchEnabled: Bool
    let disablesProviderProbes: Bool
    let disablesSecretMigration: Bool
    let enablesSecretMigration: Bool
    let usesStatusItemAutosave: Bool

    init(environment: [String: String], isLocalBuild: Bool = Self.currentBundleIsLocalBuild()) {
        let safeLaunchEnabled = Self.isEnabled(environment[Self.safeLaunchKey])
        self.safeLaunchEnabled = safeLaunchEnabled
        self.disablesProviderProbes = safeLaunchEnabled ||
            Self.isEnabled(environment[Self.disableProviderProbesKey])
        self.disablesSecretMigration = safeLaunchEnabled ||
            Self.isEnabled(environment[Self.disableSecretMigrationKey])
        self.enablesSecretMigration = Self.isEnabled(environment[Self.enableSecretMigrationKey])
        self.usesStatusItemAutosave = Self.isEnabled(environment[Self.enableStatusItemAutosaveKey]) ||
            !Self.isEnabled(environment[Self.disableStatusItemAutosaveKey])
    }

    var startupBehavior: UsageStore.StartupBehavior {
        self.disablesProviderProbes ? .testing : .automatic
    }

    var migratesSecretsOnLaunch: Bool {
        !self.disablesSecretMigration && self.enablesSecretMigration
    }

    var disablesKeychainAccess: Bool {
        self.safeLaunchEnabled || self.disablesProviderProbes || self.disablesSecretMigration
    }

    var requestsNotificationAuthorizationOnStartup: Bool {
        !self.safeLaunchEnabled
    }

    func accountInfo(fetcher: UsageFetcher) -> AccountInfo {
        guard !self.disablesProviderProbes else {
            return AccountInfo(email: nil, plan: nil)
        }
        return fetcher.loadAccountInfo()
    }

    private static func isEnabled(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled":
            return true
        default:
            return false
        }
    }

    private static func currentBundleIsLocalBuild() -> Bool {
        Bundle.main.object(forInfoDictionaryKey: "AgentMeterLocalBuild") as? Bool == true
    }
}

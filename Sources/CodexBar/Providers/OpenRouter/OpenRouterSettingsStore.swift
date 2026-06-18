import CodexBarCore
import Foundation

extension SettingsStore {
    var openRouterAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .openrouter)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .openrouter) { entry in
                self.setProviderSecret(newValue, field: .apiKey, entry: &entry)
            }
            self.logSecretUpdate(provider: .openrouter, field: "apiKey", value: newValue)
        }
    }
}

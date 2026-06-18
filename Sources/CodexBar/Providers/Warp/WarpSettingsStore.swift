import CodexBarCore
import Foundation

extension SettingsStore {
    var warpAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .warp)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .warp) { entry in
                self.setProviderSecret(newValue, field: .apiKey, entry: &entry)
            }
            self.logSecretUpdate(provider: .warp, field: "apiKey", value: newValue)
        }
    }
}

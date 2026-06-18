import CodexBarCore
import Foundation

extension SettingsStore {
    var syntheticAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .synthetic)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .synthetic) { entry in
                self.setProviderSecret(newValue, field: .apiKey, entry: &entry)
            }
            self.logSecretUpdate(provider: .synthetic, field: "apiKey", value: newValue)
        }
    }

    func ensureSyntheticAPITokenLoaded() {}
}

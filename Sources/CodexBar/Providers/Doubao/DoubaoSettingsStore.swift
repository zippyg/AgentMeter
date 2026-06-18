import CodexBarCore
import Foundation

extension SettingsStore {
    var doubaoAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .doubao)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .doubao) { entry in
                self.setProviderSecret(newValue, field: .apiKey, entry: &entry)
            }
            self.logSecretUpdate(provider: .doubao, field: "apiKey", value: newValue)
        }
    }
}

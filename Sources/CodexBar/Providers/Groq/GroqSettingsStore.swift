import CodexBarCore
import Foundation

extension SettingsStore {
    var groqAPIKey: String {
        get {
            self.configSnapshot.providerConfig(for: .groq)?.sanitizedAPIKey ?? ""
        }
        set {
            self.updateProviderConfig(provider: .groq) { entry in
                self.setProviderSecret(newValue, field: .apiKey, entry: &entry)
            }
            self.logSecretUpdate(provider: .groq, field: "apiKey", value: newValue)
        }
    }
}

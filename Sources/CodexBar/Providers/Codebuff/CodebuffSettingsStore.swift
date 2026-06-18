import CodexBarCore
import Foundation

extension SettingsStore {
    var codebuffAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .codebuff)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .codebuff) { entry in
                self.setProviderSecret(newValue, field: .apiKey, entry: &entry)
            }
            self.logSecretUpdate(provider: .codebuff, field: "apiKey", value: newValue)
        }
    }
}

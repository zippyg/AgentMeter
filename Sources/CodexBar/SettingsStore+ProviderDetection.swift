import CodexBarCore
import Foundation

extension SettingsStore {
    func runInitialProviderDetectionIfNeeded(force: Bool = false) {
        guard force || !self.providerDetectionCompleted else { return }
        LoginShellPathCache.shared.captureOnce { [weak self] _ in
            Task { @MainActor in
                await self?.applyProviderDetection()
            }
        }
    }

    func applyProviderDetection() async {
        guard !self.providerDetectionCompleted else { return }
        let codexInstalled = BinaryLocator.resolveCodexBinary() != nil
        let claudeInstalled = BinaryLocator.resolveClaudeBinary() != nil
        let geminiInstalled = BinaryLocator.resolveGeminiBinary() != nil
        let antigravityRunning = await AntigravityStatusProbe.isRunning()
        let antigravityLoggedIn = FileManager.default.fileExists(
            atPath: AntigravityOAuthCredentialsStore().fileURL.path)
        let logger = CodexBarLog.logger(LogCategories.providerDetection)

        logger.info(
            "Provider detection results",
            metadata: [
                "codexInstalled": codexInstalled ? "1" : "0",
                "claudeInstalled": claudeInstalled ? "1" : "0",
                "geminiInstalled": geminiInstalled ? "1" : "0",
                "antigravityRunning": antigravityRunning ? "1" : "0",
                "antigravityLoggedIn": antigravityLoggedIn ? "1" : "0",
            ])
        logger.info(
            "Provider detection enablement",
            metadata: [
                "codex": "1",
                "claude": "1",
                "gemini": "0",
                "antigravityAvailable": (antigravityRunning || antigravityLoggedIn) ? "1" : "0",
                "antigravity": "0",
            ])

        self.updateProviderConfig(provider: .codex) { entry in
            entry.enabled = true
        }
        self.updateProviderConfig(provider: .claude) { entry in
            entry.enabled = true
        }
        self.updateProviderConfig(provider: .gemini) { entry in
            entry.enabled = false
        }
        self.updateProviderConfig(provider: .antigravity) { entry in
            entry.enabled = false
        }
        self.providerDetectionCompleted = true
        logger.info("Provider detection completed")
    }
}

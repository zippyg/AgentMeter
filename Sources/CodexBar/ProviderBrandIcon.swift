import AppKit
import CodexBarCore

@MainActor
enum ProviderBrandIcon {
    private static let size = NSSize(width: 16, height: 16)
    private static var cache: [UsageProvider: NSImage] = [:]
    private static var wordmarkCache: [String: NSImage] = [:]

    /// Lazy-loaded resource bundle for provider icons.
    private static let resourceBundle: Bundle? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return Bundle.module
        }
        // SwiftPM creates an AgentMeter_AgentMeter.bundle for resources in the AgentMeter target.
        if let bundleURL = Bundle.main.url(forResource: "AgentMeter_AgentMeter", withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL)
        {
            return bundle
        }
        // Fallback to main bundle for development/testing.
        return Bundle.main
    }()

    static func image(for provider: UsageProvider) -> NSImage? {
        if let cached = self.cache[provider] {
            return cached
        }

        let baseName = ProviderDescriptorRegistry.descriptor(for: provider).branding.iconResourceName
        guard let bundle = self.resourceBundle else {
            return nil
        }
        guard let url = bundle.url(forResource: baseName, withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        image.size = self.size
        image.isTemplate = self.usesTemplateRendering(for: provider)
        self.cache[provider] = image
        return image
    }

    static func usesTemplateRendering(for provider: UsageProvider) -> Bool {
        provider != .claude
    }

    static func wordmark(for provider: UsageProvider, dark: Bool) -> NSImage? {
        guard let baseName = self.wordmarkResourceName(for: provider, dark: dark) else { return nil }
        if let cached = self.wordmarkCache[baseName] {
            return cached
        }
        guard let bundle = self.resourceBundle,
              let url = bundle.url(forResource: baseName, withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        image.isTemplate = false
        self.wordmarkCache[baseName] = image
        return image
    }

    static func resetCacheForTesting() {
        self.cache.removeAll()
        self.wordmarkCache.removeAll()
    }

    private static func wordmarkResourceName(for provider: UsageProvider, dark: Bool) -> String? {
        switch provider {
        case .claude:
            dark ? "ProviderWordmark-claude-dark" : "ProviderWordmark-claude"
        case .codex:
            dark ? "ProviderWordmark-codex-dark" : "ProviderWordmark-codex"
        default:
            nil
        }
    }
}

import SwiftUI

enum AgentMeterProviderAsset {
    static func iconName(for providerID: String) -> String? {
        switch providerID {
        case "claude":
            "ClaudeAIIcon"
        case "codex":
            "CodexIcon"
        case "claudeCode":
            "ClaudeCodeIcon"
        default:
            nil
        }
    }

    static func wordmarkName(for providerID: String) -> String? {
        switch providerID {
        case "claude":
            "ClaudeAIWordmark"
        case "codex":
            "CodexWordmark"
        default:
            nil
        }
    }

    static func fallbackSystemName(for providerID: String) -> String {
        providerID == "codex" ? "terminal" : "sparkle"
    }
}

enum AgentMeterIdentityAsset {
    static let imageName = "AgentMeterIdentityIcon"
}

struct AgentMeterIdentityMark: View {
    let size: CGFloat

    var body: some View {
        Image(AgentMeterIdentityAsset.imageName)
            .resizable()
            .scaledToFit()
            .frame(width: self.size, height: self.size)
            .accessibilityLabel("AgentMeter")
    }
}

struct AgentMeterProviderIcon: View {
    let providerID: String
    var size: CGFloat = 18

    var body: some View {
        if let name = AgentMeterProviderAsset.iconName(for: self.providerID) {
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: self.size, height: self.size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: AgentMeterProviderAsset.fallbackSystemName(for: self.providerID))
                .font(.system(size: self.size * 0.72, weight: .semibold))
                .frame(width: self.size, height: self.size)
                .accessibilityHidden(true)
        }
    }
}

struct AgentMeterProviderWordmark: View {
    let providerID: String
    let fallbackTitle: String
    var height: CGFloat = 18

    var body: some View {
        if let name = AgentMeterProviderAsset.wordmarkName(for: self.providerID) {
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(height: self.height)
                .accessibilityLabel(self.fallbackTitle)
        } else {
            Text(self.fallbackTitle)
                .font(.headline)
                .accessibilityLabel(self.fallbackTitle)
        }
    }
}

struct AgentMeterProviderLockup: View {
    let providerID: String
    let fallbackTitle: String
    var iconSize: CGFloat = 18
    var wordmarkHeight: CGFloat = 16

    var body: some View {
        if self.providerID == "claude" {
            AgentMeterProviderWordmark(
                providerID: self.providerID,
                fallbackTitle: self.fallbackTitle,
                height: self.wordmarkHeight)
            .frame(maxWidth: self.wordmarkHeight * 7.2, alignment: .leading)
            .accessibilityLabel(self.fallbackTitle)
        } else {
            HStack(spacing: 7) {
                AgentMeterProviderIcon(providerID: self.providerID, size: self.iconSize)
                AgentMeterProviderWordmark(
                    providerID: self.providerID,
                    fallbackTitle: self.fallbackTitle,
                    height: self.wordmarkHeight)
                .frame(maxWidth: self.wordmarkHeight * 6.5, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(self.fallbackTitle)
        }
    }
}

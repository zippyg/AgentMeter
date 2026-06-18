import Foundation

#if canImport(ActivityKit)
import ActivityKit

struct AgentMeterActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var snapshot: AgentMeterActivitySnapshot
        var updatedAt: Date
    }

    var title: String
}

struct AgentMeterActivitySnapshot: Codable, Hashable {
    var generatedAt: Date
    var providers: [AgentMeterActivityProvider]

    init(snapshot: AgentMeterPhoneSnapshot) {
        self.generatedAt = snapshot.generatedAt
        self.providers = snapshot.providers.map(AgentMeterActivityProvider.init(provider:))
    }

    var peakSessionUsedPercent: Double? {
        self.providers.compactMap(\.sessionWindow?.usedPercent).max()
    }
}

struct AgentMeterActivityProvider: Codable, Hashable, Identifiable {
    var id: String
    var displayName: String
    var sessionWindow: AgentMeterActivityWindow?
    var weeklyWindow: AgentMeterActivityWindow?
    var status: String

    init(provider: AgentMeterPhoneProvider) {
        self.id = provider.id
        self.displayName = provider.displayName
        self.sessionWindow = provider.primaryWindow.map(AgentMeterActivityWindow.init(window:))
        self.weeklyWindow = provider.weeklyWindow.map(AgentMeterActivityWindow.init(window:))
        self.status = provider.status.rawValue
    }
}

struct AgentMeterActivityWindow: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var usedPercent: Double?
    var resetsAt: Date?
    var resetDescription: String?
    var windowMinutes: Int?

    init(window: AgentMeterPhoneUsageWindow) {
        self.id = window.id
        self.title = window.title
        self.usedPercent = window.usedPercent
        self.resetsAt = window.resetsAt
        self.resetDescription = window.resetDescription
        self.windowMinutes = window.windowMinutes
    }

    func phoneWindow() -> AgentMeterPhoneUsageWindow {
        AgentMeterPhoneUsageWindow(
            id: self.id,
            title: self.title,
            usedPercent: self.usedPercent,
            remainingPercent: nil,
            resetsAt: self.resetsAt,
            resetDescription: self.resetDescription,
            windowMinutes: self.windowMinutes)
    }
}
#endif

import CodexBarCore
import Foundation

enum AgentMeterMascotMood: String, Equatable, Sendable {
    case happy
    case neutral
    case sad
}

enum AgentMeterMascotMoodResolver {
    private static let trackedProviders: [UsageProvider] = [.claude, .codex]

    @MainActor
    static func mood(store: UsageStore) -> AgentMeterMascotMood {
        let pressures = self.trackedProviders.compactMap { provider in
            self.providerPressure(provider: provider, store: store)
        }
        return self.mood(providerPressures: pressures)
    }

    static func mood(providerPressures: [Double]) -> AgentMeterMascotMood {
        let pressures = providerPressures.map(self.clamp)
        guard !pressures.isEmpty else { return .neutral }

        if pressures.contains(where: { $0 >= 90 }) {
            return .sad
        }

        let average = pressures.reduce(0, +) / Double(pressures.count)
        if average >= 80 {
            return .sad
        }
        if average < 40, pressures.allSatisfy({ $0 < 60 }) {
            return .happy
        }
        return .neutral
    }

    static func providerPressure(snapshot: UsageSnapshot) -> Double? {
        var windows = [snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap(\.self)
        windows.append(contentsOf: snapshot.extraRateWindows?.filter(\.usageKnown).map(\.window) ?? [])
        guard !windows.isEmpty else { return nil }
        return windows.map { self.clamp($0.usedPercent) }.max()
    }

    @MainActor
    private static func providerPressure(provider: UsageProvider, store: UsageStore) -> Double? {
        guard !store.isStale(provider: provider),
              let snapshot = store.snapshot(for: provider)
        else {
            return nil
        }
        return self.providerPressure(snapshot: snapshot)
    }

    private static func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}

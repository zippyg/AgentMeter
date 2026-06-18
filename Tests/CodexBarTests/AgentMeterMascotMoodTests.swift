import AppKit
import CodexBarCore
import Testing
@testable import AgentMeter

@Suite("AgentMeter mascot mood")
struct AgentMeterMascotMoodTests {
    @Test
    func usagePressureMapsToExpectedMood() {
        #expect(AgentMeterMascotMoodResolver.mood(providerPressures: []) == .neutral)
        #expect(AgentMeterMascotMoodResolver.mood(providerPressures: [18, 31]) == .happy)
        #expect(AgentMeterMascotMoodResolver.mood(providerPressures: [39, 61]) == .neutral)
        #expect(AgentMeterMascotMoodResolver.mood(providerPressures: [55, 72]) == .neutral)
        #expect(AgentMeterMascotMoodResolver.mood(providerPressures: [79, 81]) == .sad)
        #expect(AgentMeterMascotMoodResolver.mood(providerPressures: [12, 92]) == .sad)
        #expect(AgentMeterMascotMoodResolver.mood(providerPressures: [-20, 20]) == .happy)
        #expect(AgentMeterMascotMoodResolver.mood(providerPressures: [120]) == .sad)
    }

    @Test
    func providerPressureUsesHighestKnownWindow() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: "daily"),
            secondary: RateWindow(usedPercent: 67, windowMinutes: nil, resetsAt: nil, resetDescription: "weekly"),
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "ignored",
                    title: "Unknown",
                    window: RateWindow(
                        usedPercent: 100,
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: nil),
                    usageKnown: false),
                NamedRateWindow(
                    id: "monthly",
                    title: "Monthly",
                    window: RateWindow(
                        usedPercent: 91,
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: "month")),
            ],
            updatedAt: Date())

        #expect(AgentMeterMascotMoodResolver.providerPressure(snapshot: snapshot) == 91)
    }

    @MainActor
    @Test
    func staleProvidersDoNotDriveMood() throws {
        let suite = "AgentMeterMascotMoodTests-stale-providers"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 95, windowMinutes: nil, resetsAt: nil, resetDescription: "soon"),
                secondary: nil,
                updatedAt: Date(timeIntervalSinceNow: -10 * 60)),
            provider: .claude)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: "later"),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)
        store._setErrorForTesting("stale", provider: .claude)

        #expect(AgentMeterMascotMoodResolver.mood(store: store) == .happy)
    }

    @Test
    func moodChangesRenderedMouthPixels() throws {
        let happy = try bitmap(for: .happy)
        let neutral = try bitmap(for: .neutral)
        let sad = try bitmap(for: .sad)

        #expect(happy.pixelsWide == 36)
        #expect(happy.pixelsHigh == 36)
        #expect(neutral.pixelsWide == 36)
        #expect(sad.pixelsHigh == 36)
        #expect(happy.bitmapDataHash != neutral.bitmapDataHash)
        #expect(sad.bitmapDataHash != neutral.bitmapDataHash)
        #expect(happy.bitmapDataHash != sad.bitmapDataHash)
    }

    private func bitmap(for mood: AgentMeterMascotMood) throws -> NSBitmapImageRep {
        let image = IconRenderer.makeAgentMeterIdentityIcon(stale: false, mood: mood)
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        return try #require(reps.first)
    }
}

extension NSBitmapImageRep {
    fileprivate var bitmapDataHash: Int {
        var hasher = Hasher()
        let count = self.bytesPerRow * self.pixelsHigh
        let buffer = UnsafeRawBufferPointer(start: self.bitmapData, count: count)
        hasher.combine(bytes: buffer)
        return hasher.finalize()
    }
}

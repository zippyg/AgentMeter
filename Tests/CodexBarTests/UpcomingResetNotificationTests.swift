import CodexBarCore
import Foundation
import Testing
@testable import AgentMeter

@MainActor
struct UpcomingResetNotificationTests {
    private static let start = Date(timeIntervalSince1970: 1_784_600_000)

    // MARK: - Stage logic

    @Test
    func `early warning fires within a day of the boundary and records the stage`() {
        let boundary = Self.start.addingTimeInterval(23 * 3600)
        let crossed = UpcomingResetNotificationLogic.crossedStage(
            previousState: nil,
            resetsAt: boundary,
            now: Self.start)
        #expect(crossed?.stage == .earlyWarning)
        #expect(crossed?.state.firedStages == [.earlyWarning])
        #expect(crossed?.state.resetBoundary == boundary)
    }

    @Test
    func `fired stages do not repeat for the same boundary`() {
        let boundary = Self.start.addingTimeInterval(23 * 3600)
        let first = UpcomingResetNotificationLogic.crossedStage(
            previousState: nil,
            resetsAt: boundary,
            now: Self.start)
        let second = UpcomingResetNotificationLogic.crossedStage(
            previousState: first?.state,
            resetsAt: boundary,
            now: Self.start.addingTimeInterval(60))
        #expect(second == nil)
    }

    @Test
    func `only the last call fires when both lead times already elapsed`() {
        let boundary = Self.start.addingTimeInterval(30 * 60)
        let crossed = UpcomingResetNotificationLogic.crossedStage(
            previousState: nil,
            resetsAt: boundary,
            now: Self.start)
        #expect(crossed?.stage == .lastCall)
        #expect(crossed?.state.firedStages == [.earlyWarning, .lastCall])
        #expect(UpcomingResetNotificationLogic.crossedStage(
            previousState: crossed?.state,
            resetsAt: boundary,
            now: Self.start.addingTimeInterval(60)) == nil)
    }

    @Test
    func `the last call follows the early warning for the same boundary`() {
        let boundary = Self.start.addingTimeInterval(23 * 3600)
        let early = UpcomingResetNotificationLogic.crossedStage(
            previousState: nil,
            resetsAt: boundary,
            now: Self.start)
        let lastCall = UpcomingResetNotificationLogic.crossedStage(
            previousState: early?.state,
            resetsAt: boundary,
            now: boundary.addingTimeInterval(-30 * 60))
        #expect(lastCall?.stage == .lastCall)
        #expect(lastCall?.state.firedStages == [.earlyWarning, .lastCall])
    }

    @Test
    func `a new reset boundary re-arms every stage`() {
        let boundary = Self.start.addingTimeInterval(23 * 3600)
        let early = UpcomingResetNotificationLogic.crossedStage(
            previousState: nil,
            resetsAt: boundary,
            now: Self.start)
        let nextBoundary = boundary.addingTimeInterval(7 * 86400)
        let nextCycle = UpcomingResetNotificationLogic.crossedStage(
            previousState: early?.state,
            resetsAt: nextBoundary,
            now: nextBoundary.addingTimeInterval(-23 * 3600))
        #expect(nextCycle?.stage == .earlyWarning)
        #expect(nextCycle?.state.firedStages == [.earlyWarning])
    }

    @Test
    func `an elapsed boundary never fires`() {
        #expect(UpcomingResetNotificationLogic.crossedStage(
            previousState: nil,
            resetsAt: Self.start,
            now: Self.start) == nil)
        #expect(UpcomingResetNotificationLogic.crossedStage(
            previousState: nil,
            resetsAt: Self.start.addingTimeInterval(-60),
            now: Self.start) == nil)
    }

}

@MainActor
struct CodexQuotaReminderTests {
    static let now = Date(timeIntervalSince1970: 1_794_000_000)

    func defaults() -> UserDefaults {
        UserDefaults(suiteName: "CodexQuotaReminderTests-\(UUID().uuidString)")!
    }

    func snapshot(used: Double = 42, minutes: Int = 10080, reset: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: RateWindow(
                usedPercent: used, windowMinutes: minutes,
                resetsAt: reset ?? Self.now.addingTimeInterval(86400), resetDescription: nil),
            updatedAt: Self.now)
    }

    @Test
    func `weekly reminders persist both stages independently for each owner and boundary`() {
        let defaults = self.defaults()
        let boundary = Self.now.addingTimeInterval(86400)
        func reminders(owner: String = "invented-owner-a", now: Date = Self.now, reset: Date = boundary) -> Int {
            CodexQuotaReminderNotifier(userDefaults: defaults).reminders(
                snapshot: self.snapshot(reset: reset), owner: owner, weeklyEnabled: true, now: now).count
        }
        #expect(reminders() == 1)
        #expect(reminders() == 0)
        #expect(reminders(owner: "invented-owner-b") == 1)
        #expect(reminders(now: boundary.addingTimeInterval(-3600)) == 1)
        #expect(reminders(now: boundary.addingTimeInterval(-1800)) == 0)
        #expect(reminders(now: boundary, reset: boundary.addingTimeInterval(86400)) == 1)
        let receipts = defaults.stringArray(forKey: CodexQuotaReminderNotifier.receiptsKey) ?? []
        #expect(receipts.allSatisfy { $0.count == 64 && !$0.contains("invented-owner") })
    }

    @Test
    func `disabled unknown exhausted non weekly and elapsed windows stay silent`() {
        let notifier = CodexQuotaReminderNotifier(userDefaults: self.defaults())
        #expect(notifier.reminders(snapshot: self.snapshot(), owner: nil, weeklyEnabled: true, now: Self.now).isEmpty)
        #expect(notifier.reminders(snapshot: self.snapshot(), owner: "invented-owner", weeklyEnabled: false, now: Self.now).isEmpty)
        for snapshot in [self.snapshot(used: 100), self.snapshot(used: .nan), self.snapshot(minutes: 300),
                         self.snapshot(reset: Self.now), self.snapshot(reset: Self.now.addingTimeInterval(86401))] {
            #expect(notifier.reminders(snapshot: snapshot, owner: "invented-owner", weeklyEnabled: true, now: Self.now).isEmpty)
        }
    }

    @Test
    func `late first refresh consumes the day stage and receipt store is bounded`() {
        let defaults = self.defaults()
        let notifier = CodexQuotaReminderNotifier(userDefaults: defaults)
        let snapshot = self.snapshot(reset: Self.now.addingTimeInterval(1800))
        #expect(notifier.reminders(snapshot: snapshot, owner: "invented-owner", weeklyEnabled: true, now: Self.now).count == 1)
        #expect(defaults.stringArray(forKey: CodexQuotaReminderNotifier.receiptsKey)?.count == 2)
        for index in 0..<200 {
            _ = notifier.reminders(snapshot: snapshot, owner: "invented-owner-\(index)", weeklyEnabled: true, now: Self.now)
        }
        #expect(defaults.stringArray(forKey: CodexQuotaReminderNotifier.receiptsKey)?.count == CodexQuotaReminderNotifier.maximumReceipts)
    }

    @Test
    func `weekly option defaults off and persists`() {
        let defaults = self.defaults()
        let suite = "CodexQuotaReminderSettings-\(UUID().uuidString)"
        func settings() -> SettingsStore {
            SettingsStore(userDefaults: defaults, configStore: testConfigStore(suiteName: suite),
                          zaiTokenStore: NoopZaiTokenStore(), syntheticTokenStore: NoopSyntheticTokenStore())
        }
        let original = settings()
        #expect(!original.codexResetCreditExpiryCountdownEnabled)
        original.codexResetCreditExpiryCountdownEnabled = true
        #expect(settings().codexResetCreditExpiryCountdownEnabled)
        #expect(!original.upcomingResetNotificationsEnabled)
        original.upcomingResetNotificationsEnabled = true
        #expect(settings().upcomingResetNotificationsEnabled)
    }
}

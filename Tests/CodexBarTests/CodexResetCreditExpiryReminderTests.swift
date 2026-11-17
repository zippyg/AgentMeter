@testable import CodexBarCore
import Foundation
import Testing
@testable import AgentMeter

@MainActor
struct CodexResetCreditExpiryReminderTests {
    private let now = CodexQuotaReminderTests.now

    private func snapshot(
        status: String = "available",
        id: String? = "invented-reset",
        expiry: Date?) throws -> UsageSnapshot
    {
        var credit: [String: Any] = ["status": status]
        credit["id"] = id
        credit["expires_at"] = expiry?.timeIntervalSince1970
        let data = try JSONSerialization.data(withJSONObject: ["credits": [credit]])
        return UsageSnapshot(
            primary: nil, secondary: nil,
            codexResetCredits: try JSONDecoder().decode(CodexResetCredits.self, from: data), updatedAt: self.now)
    }

    @Test
    func `expiry countdowns fire once at one day and one hour across notifier instances`() throws {
        let defaults = CodexQuotaReminderTests().defaults()
        let boundary = self.now.addingTimeInterval(86400)
        let snapshot = try self.snapshot(expiry: boundary)
        func reminders(at date: Date, owner: String = "invented-owner") -> Int {
            CodexQuotaReminderNotifier(userDefaults: defaults).reminders(
                snapshot: snapshot, owner: owner, weeklyEnabled: false,
                creditExpiryEnabled: true, now: date).count
        }
        #expect(reminders(at: self.now.addingTimeInterval(-1)) == 0)
        #expect(reminders(at: self.now) == 1)
        #expect(reminders(at: self.now) == 0)
        #expect(reminders(at: boundary.addingTimeInterval(-3600)) == 1)
        #expect(reminders(at: boundary.addingTimeInterval(-1800)) == 0)
        #expect(reminders(at: self.now, owner: "invented-other-owner") == 1)
    }

    @Test(arguments: ["redeeming", "redeemed", "expired", "unknown"])
    func `unavailable reset credits do not notify`(status: String) throws {
        let notifier = CodexQuotaReminderNotifier(userDefaults: CodexQuotaReminderTests().defaults())
        #expect(try notifier.reminders(
            snapshot: self.snapshot(status: status, expiry: self.now.addingTimeInterval(1800)),
            owner: "invented-owner", weeklyEnabled: false, creditExpiryEnabled: true, now: self.now).isEmpty)
    }

    @Test
    func `disabled unknown owner no expiry missing id expired and summary only inventories stay silent`() throws {
        let notifier = CodexQuotaReminderNotifier(userDefaults: CodexQuotaReminderTests().defaults())
        let valid = try self.snapshot(expiry: self.now.addingTimeInterval(1800))
        #expect(notifier.reminders(snapshot: valid, owner: nil, weeklyEnabled: false, creditExpiryEnabled: true, now: self.now).isEmpty)
        #expect(notifier.reminders(snapshot: valid, owner: "invented-owner", weeklyEnabled: false, now: self.now).isEmpty)
        let summary = UsageSnapshot(primary: nil, secondary: nil,
                                    codexResetCredits: CodexResetCredits(availableCount: 3, credits: nil), updatedAt: self.now)
        for snapshot in [try self.snapshot(expiry: nil), try self.snapshot(id: nil, expiry: self.now.addingTimeInterval(1800)),
                         try self.snapshot(expiry: self.now), summary] {
            #expect(notifier.reminders(snapshot: snapshot, owner: "invented-owner", weeklyEnabled: false,
                                      creditExpiryEnabled: true, now: self.now).isEmpty)
        }
    }

    @Test
    func `late first expiry consumes day stage and distinct credits keep independent receipts`() throws {
        let defaults = CodexQuotaReminderTests().defaults()
        let notifier = CodexQuotaReminderNotifier(userDefaults: defaults)
        let expiry = self.now.addingTimeInterval(1800)
        for id in ["invented-reset-a", "invented-reset-b"] {
            let snapshot = try self.snapshot(id: id, expiry: expiry)
            #expect(notifier.reminders(snapshot: snapshot, owner: "invented-owner", weeklyEnabled: false,
                                      creditExpiryEnabled: true, now: self.now).count == 1)
        }
        #expect(defaults.stringArray(forKey: CodexQuotaReminderNotifier.receiptsKey)?.count == 4)
    }
}

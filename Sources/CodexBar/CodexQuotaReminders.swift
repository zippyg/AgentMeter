import CodexBarCore
import CryptoKit
import Foundation

// Adapted from upstream 365db9638 and a8b880d8f. Each receipt belongs to one owner and boundary.
enum UpcomingResetStage: Int, Codable, CaseIterable, Equatable {
    case earlyWarning
    case lastCall

    var leadTime: TimeInterval {
        switch self {
        case .earlyWarning: 86400
        case .lastCall: 3600
        }
    }
}

struct UpcomingResetNotificationState: Codable, Equatable {
    let resetBoundary: Date
    var firedStages: Set<UpcomingResetStage>
}

enum UpcomingResetNotificationLogic {
    static func crossedStage(
        previousState: UpcomingResetNotificationState?,
        resetsAt: Date,
        now: Date) -> (stage: UpcomingResetStage, state: UpcomingResetNotificationState)?
    {
        guard resetsAt > now else { return nil }
        var state = previousState.flatMap { $0.resetBoundary == resetsAt ? $0 : nil }
            ?? UpcomingResetNotificationState(resetBoundary: resetsAt, firedStages: [])
        guard let stage = UpcomingResetStage.allCases
            .last(where: { resetsAt.timeIntervalSince(now) <= $0.leadTime }),
            !state.firedStages.contains(stage)
        else { return nil }
        // A late first refresh consumes earlier stages instead of replaying them.
        state.firedStages.formUnion(UpcomingResetStage.allCases.filter { $0.rawValue <= stage.rawValue })
        return (stage, state)
    }
}

@MainActor
struct CodexQuotaReminderNotifier {
    enum Kind { case weekly, creditExpiry }
    struct Reminder {
        let kind: Kind
        let title: String
        let body: String
    }

    static let receiptsKey = "codexQuotaReminderReceipts"
    static let maximumReceipts = 192
    let userDefaults: UserDefaults

    func reminders(
        snapshot: UsageSnapshot,
        owner: String?,
        weeklyEnabled: Bool,
        creditExpiryEnabled: Bool = false,
        now: Date) -> [Reminder]
    {
        guard let owner, !owner.isEmpty, weeklyEnabled || creditExpiryEnabled else { return [] }
        var receipts = self.userDefaults.stringArray(forKey: Self.receiptsKey) ?? []
        var reminders: [Reminder] = []
        func consume(_ kind: String, id: String, boundary: Date) -> Bool {
            guard let crossed = UpcomingResetNotificationLogic.crossedStage(
                previousState: nil, resetsAt: boundary, now: now)
            else { return false }
            func receipt(_ stage: UpcomingResetStage) -> String {
                let material = "\(owner)\u{1f}\(kind)\u{1f}\(id)\u{1f}\(boundary.timeIntervalSince1970)\u{1f}\(stage.rawValue)"
                return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            guard !receipts.contains(receipt(crossed.stage)) else { return false }
            for stage in crossed.state.firedStages {
                let key = receipt(stage)
                if !receipts.contains(key) { receipts.append(key) }
            }
            return true
        }
        if weeklyEnabled,
           let weekly = snapshot.secondary, weekly.windowMinutes == 10080,
           weekly.remainingPercent.isFinite, weekly.remainingPercent > 0,
           let boundary = weekly.resetsAt,
           consume("weekly", id: "weekly", boundary: boundary)
        {
            reminders.append(Reminder(
                kind: .weekly,
                title: L("Codex weekly quota resets soon"),
                body: String(format: L("%@ left. %@."),
                             String(format: "%.0f%%", weekly.remainingPercent),
                             UsageFormatter.resetCountdownDescription(from: boundary, now: now))))
        }
        if creditExpiryEnabled {
            for credit in snapshot.codexResetCredits?.credits ?? [] {
                guard credit.status == "available", let id = credit.id, !id.isEmpty,
                      let boundary = credit.expiresAt,
                      consume("credit", id: id, boundary: boundary)
                else { continue }
                reminders.append(Reminder(
                    kind: .creditExpiry,
                    title: L("Codex full reset credit expires soon"),
                    body: UsageFormatter.resetCountdownDescription(from: boundary, now: now)))
            }
        }
        self.userDefaults.set(Array(receipts.suffix(Self.maximumReceipts)), forKey: Self.receiptsKey)
        return reminders
    }
}

extension UsageStore {
    func handleCodexQuotaReminders(
        snapshot: UsageSnapshot,
        owner: String?,
        now: Date = .init())
    {
        guard self.isEnabled(.codex) else { return }
        let reminders = CodexQuotaReminderNotifier(userDefaults: self.settings.userDefaults).reminders(
            snapshot: snapshot,
            owner: owner,
            weeklyEnabled: self.settings.upcomingResetNotificationsEnabled,
            creditExpiryEnabled: self.settings.codexResetCreditExpiryCountdownEnabled,
            now: now)
        for reminder in reminders {
            let isWeekly = reminder.kind == .weekly
            AppNotifications.shared.post(
                idPrefix: isWeekly ? "codex-upcoming-reset" : "codex-reset-credit-countdown",
                title: reminder.title,
                body: reminder.body,
                isCurrent: { [weak self] in
                    guard let self, self.isEnabled(.codex),
                          self.codexOwnershipContext().canonicalKey == owner else { return false }
                    return isWeekly ? self.settings.upcomingResetNotificationsEnabled
                        : self.settings.codexResetCreditExpiryCountdownEnabled
                })
        }
    }
}

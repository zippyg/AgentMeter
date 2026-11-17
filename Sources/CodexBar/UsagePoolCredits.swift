import CodexBarCore
import Foundation
import SwiftUI

struct UsagePoolCreditCap: Decodable {
    let floor: Double
    let cap: Double

    private enum CodingKeys: String, CodingKey {
        case floor = "credit_floor"
        case cap = "credit_cap"
    }

    static func load(from url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/codex-overflow.json")) -> Self?
    {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Self.self, from: data),
              config.floor.isFinite, config.floor >= 0, config.cap.isFinite, config.cap > 0 else { return nil }
        return config
    }

    func left(balance: Double) -> Double { min(self.cap, max(0, balance - self.floor)) }
    func used(balance: Double) -> Double { self.cap - self.left(balance: balance) }
}

struct UsagePoolCredits {
    let balance: Double
    let cap: UsagePoolCreditCap?
    let usageText: String

    init?(account: UsagePoolForecast.Account, balance: Double?, cap: UsagePoolCreditCap?, now: Date) {
        guard let balance, balance.isFinite, balance > 0,
              let window = [account.session, account.weekly].compactMap({ $0 }).first(where: {
                  $0.usedPercent.rounded() >= 100 && $0.resetsAt.map { $0 > now } != false
              }) else { return nil }
        self.balance = balance
        self.cap = cap
        self.usageText = UsagePoolViewModel.usageText(
            window, unreadable: account.refusedSince != nil, estimated: false, now: now, creditsRemaining: balance)
    }

    /// The per-account details card shows the balance and cap whether or not the login is on credits now.
    init?(balance: Double?, cap: UsagePoolCreditCap?) {
        guard let balance, balance.isFinite, balance >= 0 else { return nil }
        self.balance = balance
        self.cap = cap
        self.usageText = ""
    }

    var usedPercent: Double? { self.cap.map { $0.used(balance: self.balance) / $0.cap * 100 } }
    var capReached: Bool { self.cap.map { $0.left(balance: self.balance) < 0.5 } ?? false }

    func balanceText(locale: Locale = .current) -> String {
        self.balance.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }

    func capText(locale: Locale = .current) -> String? {
        guard let cap else { return nil }
        if self.capReached { return "Cap reached" }
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)).locale(locale)
        return "\(cap.left(balance: self.balance).formatted(format)) of \(cap.cap.formatted(format)) left"
    }
}

struct UsagePoolCreditsView: View {
    let credits: UsagePoolCredits
    let tint: Color
    var showsBalance = true

    var capTint: Color {
        guard let used = self.credits.usedPercent else { return self.tint }
        return self.credits.capReached ? .red : used >= 80 ? .orange : self.tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if self.showsBalance {
                HStack {
                    Text("Credits").foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(self.credits.balanceText())
                }
            }
            if let text = self.credits.capText(), let used = self.credits.usedPercent {
                HStack {
                    Text("Credit cap").foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(text).foregroundStyle(self.credits.capReached ? Color.red : .primary)
                }
                UsageProgressBar(percent: used, tint: self.capTint, accessibilityLabel: "Credit cap used")
            }
        }
        .font(.system(size: 12)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        .accessibilityElement(children: .combine)
    }
}

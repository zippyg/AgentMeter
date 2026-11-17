import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import AgentMeter

struct UsagePoolCreditsTests {
    private let now = Date(timeIntervalSince1970: 1_794_312_000)
    private let cap = UsagePoolCreditCap(floor: 1000.25, cap: 500)

    private func credits(balance: Double? = 1460.95, used: Double = 100,
                         resetOffset: Double? = 3600, cap: UsagePoolCreditCap? = nil) -> UsagePoolCredits? {
        let account = UsagePoolForecast.Account(id: "invented", displayName: "Pro 20x",
            weekly: .init(usedPercent: used, windowMinutes: 10080,
                resetsAt: resetOffset.map { self.now.addingTimeInterval($0) }, resetDescription: nil))
        return UsagePoolCredits(account: account, balance: balance, cap: cap, now: self.now)
    }

    @Test func loaderReadsOnlyValidCapKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("overflow.json")
        #expect(UsagePoolCreditCap.load(from: url) == nil)
        for json in [#"{"credit_floor":1000.25}"#, #"{"credit_cap":500}"#, "bad JSON",
                     #"{"credit_floor":0,"credit_cap":0}"#, #"{"credit_floor":-1,"credit_cap":500}"#] {
            try Data(json.utf8).write(to: url)
            #expect(UsagePoolCreditCap.load(from: url) == nil)
        }
        try Data(#"{"home":"invented","credit_floor":1000.25,"credit_cap":500}"#.utf8).write(to: url)
        let loaded = try #require(UsagePoolCreditCap.load(from: url))
        #expect(loaded.floor == 1000.25 && loaded.cap == 500)
        #expect(UsagePoolCreditCap.load(from: directory) == nil)
    }

    @Test func capMathClampsBothEnds() {
        for (balance, left, used) in [(1460.95, 460.7, 39.3), (1000.25, 0.0, 500.0),
                                      (900, 0, 500), (2000, 500, 0)] {
            #expect(abs(self.cap.left(balance: balance) - left) < 0.000001)
            #expect(abs(self.cap.used(balance: balance) - used) < 0.000001)
        }
    }

    @MainActor
    @Test func textAndTintFollowCapState() throws {
        let locale = Locale(identifier: "en_US")
        let balanceOnly = try #require(self.credits())
        #expect(balanceOnly.usageText == "100% used · on credits")
        #expect(balanceOnly.balanceText(locale: locale) == "1,461")
        #expect(balanceOnly.balanceText(locale: Locale(identifier: "de_DE")) == "1.461")
        #expect(balanceOnly.capText() == nil && balanceOnly.usedPercent == nil)
        let normal = try #require(self.credits(cap: self.cap))
        #expect(normal.capText(locale: locale) == "461 of 500 left")
        #expect(UsagePoolCreditsView(credits: normal, tint: .blue).capTint == .blue)
        let warning = try #require(self.credits(balance: self.cap.floor + 100, cap: self.cap))
        #expect(warning.usedPercent == 80)
        #expect(warning.capText(locale: locale) == "100 of 500 left")
        #expect(UsagePoolCreditsView(credits: warning, tint: .blue).capTint == .orange)
        for balance in [self.cap.floor, self.cap.floor - 1] {
            let reached = try #require(self.credits(balance: balance, cap: self.cap))
            #expect(reached.capText() == "Cap reached")
            #expect(reached.usedPercent == 100)
            #expect(UsagePoolCreditsView(credits: reached, tint: .blue).capTint == .red)
        }
        #expect(self.credits(balance: 2000, cap: self.cap)?.capText(locale: locale) == "500 of 500 left")
        // Under half a credit left would print "0 of 500 left"; it counts as reached.
        let nearlyReached = try #require(self.credits(balance: self.cap.floor + 0.3, cap: self.cap))
        #expect(nearlyReached.capText() == "Cap reached")
        #expect(UsagePoolCreditsView(credits: nearlyReached, tint: .blue).capTint == .red)
    }

    @Test func blockRequiresPositiveBalanceAndExhaustedCurrentWindow() {
        for balance in [nil, 0, -1, Double.nan, Double.infinity] {
            #expect(self.credits(balance: balance) == nil)
        }
        for used in [0.0, 95, 99.4] { #expect(self.credits(used: used) == nil) }
        // Same rounding as the usage line, which shows 99.5% as "100% used".
        #expect(self.credits(used: 99.5) != nil)
        #expect(self.credits(resetOffset: 0) == nil)
        #expect(self.credits(resetOffset: -1) == nil)
        #expect(self.credits(resetOffset: nil) != nil)
        #expect(self.credits(used: 105)?.usageText == "105% used · on credits")
    }
}

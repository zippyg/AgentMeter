import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeSwapUsageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func accountsStaySeparateAndRoundTripToPhone() throws {
        let data = Data(#"""
        {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
          {"number":1,"email":"synthetic@example.invalid","alias":"ignored","usageStatus":"ok",
           "usage":{"fiveHour":{"pct":1,"resetsAt":"2027-01-15T12:00:00.123Z"},
                    "sevenDay":{"pct":9},"scoped":[{"name":"Sonnet","pct":12}]}},
          {"number":2,"active":true,"usageStatus":"ok","usage":{"fiveHour":{"pct":70},"sevenDay":{"pct":80}}}
        ]}
        """#.utf8)
        let accounts = try ClaudeSwapUsage.parse(data, now: self.now)
        #expect(accounts.map(\.id) == ["claude:cswap:1", "claude:cswap:2"])
        #expect(accounts.map(\.isActiveCLI) == [false, true])
        #expect(accounts[0].windows.map(\.id) == ["session", "weekly", "model:sonnet"])
        #expect(accounts[0].windows[0].resetsAt != nil)
        #expect(accounts[0].claudeSwapUsageSnapshot.extraRateWindows?.count == 1)
        #expect(accounts[1].windows[0].usedPercent == 70)
        #expect(accounts.allSatisfy { $0.spend == nil && $0.plan == nil })
        let summary = AgentMeterSnapshot(generatedAt: self.now, providers: accounts)
        let summaryCopy = try JSONDecoder().decode(AgentMeterSnapshot.self, from: JSONEncoder().encode(summary))
        // The alias names the card but is display state, so it is the one field the copy loses.
        let sorted = JSONEncoder()
        sorted.outputFormatting = .sortedKeys
        #expect(try sorted.encode(summaryCopy) == sorted.encode(summary))
        #expect(accounts[0].accountDisplayHint == "ignored")
        #expect(summaryCopy.providers.allSatisfy { $0.accountDisplayHint == nil })
        let phone = AgentMeterPhoneSnapshot(agentMeterSnapshot: summary)
        #expect(phone.providers.count == 2)
        let encoded = try JSONEncoder().encode(phone)
        let decoded = try JSONDecoder().decode(AgentMeterPhoneSnapshot.self, from: encoded)
        #expect(decoded.providers.map(\.accountID) == ["cswap:1", "cswap:2"])
        #expect(decoded.providers.map(\.isActiveCLI) == [false, true])
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains("synthetic@example.invalid"))
        #expect(!text.contains("ignored"))
        #expect(!AgentMeterSnapshotSecurity.containsSensitiveMaterial(encoded))
    }

    @Test func organisationNameLabelsTheSeatButNeverReachesThePhone() throws {
        let data = Data(#"""
        {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
          {"number":1,"isOrganization":true,"organizationName":"someone@example.invalid's Org","usageStatus":"ok",
           "usage":{"fiveHour":{"pct":3},"sevenDay":{"pct":4}}},
          {"number":2,"active":true,"isOrganization":true,"organizationName":"Contoso Work","usageStatus":"ok",
           "usage":{"fiveHour":{"pct":5},"sevenDay":{"pct":6}}}
        ]}
        """#.utf8)
        let accounts = try ClaudeSwapUsage.parse(data, now: self.now)

        // Both seats report isOrganization true, so the flag alone cannot tell them apart.
        // A personal seat's organisation name is generated from its email, so it is never shown.
        #expect(accounts.map(\.accountDisplayHint) == ["Personal", "Contoso Work"])
        let shown = accounts.map(\.accountDisplayName)
        #expect(!shown[0].contains("@"))
        #expect(shown[0].contains("Personal"))
        #expect(shown[1].contains("Contoso Work"))
        #expect(shown[0] != shown[1])

        // The generic label is what the saved files carry.
        #expect(accounts.map(\.accountLabel) == ["Account 1 · Organization", "Account 2 · Organization"])

        // The seat name is display state: it reaches neither file, and decodes back as nil.
        let summary = AgentMeterSnapshot(generatedAt: self.now, providers: accounts)
        let summaryText = try #require(String(data: JSONEncoder().encode(summary), encoding: .utf8))
        #expect(!summaryText.contains("@example.invalid"))
        #expect(!summaryText.contains("Contoso Work"))
        let summaryCopy = try JSONDecoder().decode(AgentMeterSnapshot.self, from: JSONEncoder().encode(summary))
        #expect(summaryCopy.providers.allSatisfy { $0.accountDisplayHint == nil })

        let phone = AgentMeterPhoneSnapshot(agentMeterSnapshot: summary)
        let phoneText = try #require(String(data: JSONEncoder().encode(phone), encoding: .utf8))
        #expect(!phoneText.contains("@example.invalid"))
        #expect(!phoneText.contains("Contoso Work"))
    }

    @Test func aliasNamesTheSeatOnlyWhenItCannotBeAnEmail() throws {
        let data = Data(#"""
        {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
          {"number":1,"alias":"someone@example.invalid","usageStatus":"ok","usage":{"fiveHour":{"pct":1}}},
          {"number":2,"active":true,"alias":" work-2 ","organizationName":"Contoso Work","usageStatus":"ok",
           "usage":{"fiveHour":{"pct":2}}},
          {"number":3,"alias":"abcdefghijklmnopqrstuvwxyz0123456","usageStatus":"ok","usage":{"fiveHour":{"pct":3}}},
          {"number":4,"alias":"","organizationName":"Contoso Work","usageStatus":"ok","usage":{"fiveHour":{"pct":4}}}
        ]}
        """#.utf8)
        let accounts = try ClaudeSwapUsage.parse(data, now: self.now)
        #expect(accounts.map(\.accountDisplayHint) == [nil, "Contoso Work · work-2", nil, "Contoso Work"])
        #expect(accounts[1].accountDisplayName.contains("work-2 · CLI active"))
        #expect(!accounts.map(\.accountDisplayName).joined().contains("@"))

        let summary = AgentMeterSnapshot(generatedAt: self.now, providers: accounts)
        let summaryText = try #require(String(data: JSONEncoder().encode(summary), encoding: .utf8))
        #expect(!summaryText.contains("@example.invalid"))
    }

    @Test func staleDisabledAndUnknownFields() throws {
        let accounts = try ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"accounts":[
          {"number":1,"usageStatus":"error","usageError":"secret raw error",
           "lastGoodUsage":{"fiveHour":{"pct":20}},"futureField":{}},
          {"number":2,"disabled":true,"usageStatus":"ok","usage":{"fiveHour":{"pct":99}}},
          {"number":3,"usageStatus":"ok","usage":{"fiveHour":{"pct":true},"sevenDay":{"pct":-5}}}
        ]}
        """#.utf8), now: self.now)
        #expect(accounts[0].status == .stale)
        #expect(accounts[0].updatedAt < self.now)
        #expect(accounts[0].windows.first?.usedPercent == 20)
        #expect(accounts[0].lastError?.contains("secret") == false)
        #expect(accounts[1].status == .unavailable)
        #expect(accounts[1].windows.first?.usedPercent == 99)
        #expect(accounts[2].windows.isEmpty)
        #expect(accounts[0].isActiveCLI == nil)
        #expect(accounts[1].isActiveCLI == false)
        #expect(accounts[2].isActiveCLI == nil)
    }

    @Test func conflictingActiveFlagsAreUnknownAndOldUsageStaysStale() throws {
        let accounts = try ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
          {"number":1,"active":true,"usageStatus":"ok","usageAgeSeconds":1800,
           "usage":{"fiveHour":{"pct":0}}},
          {"number":2,"usageStatus":"ok"}
        ]}
        """#.utf8), now: self.now)
        #expect(accounts.allSatisfy { $0.isActiveCLI == nil })
        #expect(accounts[0].status == .stale)
        #expect(accounts[0].windows.first?.usedPercent == 0)
    }

    @Test func scopedModelWindowsAndSpendUseUpstreamV1Shape() throws {
        let accounts = try ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"accounts":[
          {"number":1,"usageStatus":"ok","usage":{"fiveHour":{"pct":10},
            "scoped":[{"name":"Sonnet","pct":22,"resetsAt":"2027-01-16T12:00:00Z"},
                      {"name":"Opus","pct":7},{"name":"Bad","pct":true}],
            "spend":{"used":3,"limit":20,"currency":"GBP","pct":15}}},
          {"number":2,"usageStatus":"unavailable","lastGoodFetchedAt":"2026-01-01T00:00:00Z",
            "lastGoodUsage":{"spend":{"used":4,"limit":25,"currency":"USD"}}}
        ]}
        """#.utf8), now: self.now)
        #expect(accounts[0].windows.map(\.id) == ["session", "model:sonnet", "model:opus"])
        #expect(accounts[0].spend?.used == 3)
        #expect(accounts[0].spend?.currencyCode == "GBP")
        #expect(accounts[0].claudeSwapUsageSnapshot.providerCost?.used == 3)
        #expect(accounts[1].status == .stale)
        #expect(accounts[1].spend?.used == 4)
        #expect(accounts[1].updatedAt < self.now.addingTimeInterval(-86400))
    }

    @Test func rejectsUnknownVersionsAndAmbiguousIDs() {
        for json in [
            #"{"schemaVersion":2,"accounts":[]}"#,
            #"{"schemaVersion":true,"accounts":[]}"#,
            #"{"schemaVersion":1,"accounts":[{"number":1},{"number":1}]}"#,
            #"{"schemaVersion":1,"accounts":[{}]}"#,
        ] {
            #expect(throws: (any Error).self) { try ClaudeSwapUsage.parse(Data(json.utf8)) }
        }
    }

    @Test func spendAndCreditHistorySurvivePhoneProjection() throws {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: self.now,
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: ProviderCostSnapshot(used: 2, limit: 10, currencyCode: "GBP", updatedAt: self.now),
            creditsUsed: 4,
            creditsRemaining: 6,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let summary = AgentMeterSnapshot(widgetSnapshot: WidgetSnapshot(entries: [entry], generatedAt: self.now))
        let phone = AgentMeterPhoneSnapshot(agentMeterSnapshot: summary)
        #expect(phone.providers.first?.spend?.used == 2)
        #expect(phone.providers.first?.spend?.currencyCode == "GBP")
        #expect(phone.providers.first?.creditsUsed == 4)
        #expect(phone.providers.first?.creditsRemaining == 6)
        let copy = try JSONDecoder().decode(AgentMeterSnapshot.self, from: JSONEncoder().encode(summary))
        #expect(copy == summary)
    }
}

import Foundation
import Testing
@testable import AgentMeter
@testable import CodexBarCore

struct CodexResetCreditsTests {
    private static let fixture = """
    {
      "available_count": 3,
      "credits": [
        {"id":"invented-reset-epoch","reset_type":"codex","status":"available",
         "granted_at":1793926800,"expires_at":1794007260,"title":"Full reset","description":"Invented fixture"},
        {"id":"invented-reset-rfc3339","status":"available","granted_at":"2026-11-06T00:00:00.123Z",
         "expires_at":"2026-11-07T23:21:00Z"},
        {"id":"invented-reset-no-expiry","status":"available"},
        {"id":"invented-reset-spent","status":"redeemed","expires_at":1794007260},
        {"id":"invented-reset-redeeming","status":"redeeming","expires_at":1794007260},
        42
      ]
    }
    """

    private func decode(_ json: String = Self.fixture) throws -> CodexResetCredits {
        try JSONDecoder().decode(CodexResetCredits.self, from: Data(json.utf8))
    }

    @Test
    func decoderAcceptsOptionalFieldsAndBothTimestampFormats() throws {
        let credits = try self.decode()
        #expect(credits.availableCount == 3)
        #expect(credits.credits?.count == 5)
        #expect(credits.credits?[0].expiresAt == Date(timeIntervalSince1970: 1_794_007_260))
        #expect(credits.credits?[1].expiresAt == ISO8601DateFormatter().date(from: "2026-11-07T23:21:00Z"))
        #expect(credits.credits?[1].grantedAt != nil)
        #expect(credits.credits?[2].expiresAt == nil)
        let stringEpoch = try self.decode(#"{"credits":[{"expires_at":"1794007260"}]}"#)
        #expect(stringEpoch.credits?.first?.expiresAt == credits.credits?[0].expiresAt)
        let encoded = try JSONEncoder().encode(credits)
        let roundTrip = try JSONDecoder().decode(CodexResetCredits.self, from: encoded)
        #expect(roundTrip.credits?[0].expiresAt == credits.credits?[0].expiresAt)
        #expect(credits.credits?[0].id != nil)
        #expect(roundTrip.credits?[0].id == nil)
        let encodedObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedCredits = try #require(encodedObject["credits"] as? [[String: Any]])
        #expect(encodedCredits.allSatisfy { $0["id"] == nil })
        #expect(try self.decode("{}").credits == nil)
        #expect(try self.decode(#"{"available_count":"unknown","credits":false}"#).availableCount == nil)
        let malformed = try self.decode(#"{"credits":[{"status":"available","expires_at":"bad"}]}"#)
        #expect(malformed.credits?.first?.expiresAt == nil)
    }

    @Test
    func fetchesOnlyGETDetailsWithSameAccountAndBearer() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer invented-token")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "invented-account")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            let url = try #require(request.url)
            let payload = url.path.hasSuffix("/usage")
                ? #"{"rate_limit_reset_credits":{"available_count":3}}"# : Self.fixture
            #expect(url.path == "/backend-api/wham/usage" ||
                url.path == "/backend-api/wham/rate-limit-reset-credits")
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(payload.utf8), response)
        }
        let response = try await CodexOAuthUsageFetcher.fetchUsage(
            accessToken: "invented-token", accountId: "invented-account",
            env: ["CODEX_HOME": "/nonexistent-invented-codex-home"], session: transport)
        #expect(response.resetCredits?.credits?.count == 5)
        #expect(await transport.requests().count == 2)
    }

    @Test
    func detailFailurePreservesUsageAndCount() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let usage = url.path.hasSuffix("/usage")
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: usage ? 200 : 503, httpVersion: nil, headerFields: nil))
            return (Data(#"{"rate_limit_reset_credits":{"available_count":2}}"#.utf8), response)
        }
        let response = try await CodexOAuthUsageFetcher.fetchUsage(
            accessToken: "invented-token", accountId: nil,
            env: ["CODEX_HOME": "/nonexistent-invented-codex-home"], session: transport)
        #expect(response.resetCredits?.availableCount == 2)
        #expect(response.resetCredits?.credits == nil)
    }

    @Test
    func hungDetailsTimeoutPreservesUsageAndCount() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if !url.path.hasSuffix("/usage") {
                #expect(request.timeoutInterval == 5)
                // Simulate a stalled endpoint until the transport's request timeout.
                try await Task.sleep(for: .seconds(request.timeoutInterval))
                throw URLError(.timedOut)
            }
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            let payload = """
            {"rate_limit":{"primary_window":{"used_percent":32,"reset_at":1794007260,
            "limit_window_seconds":18000}},"rate_limit_reset_credits":{"available_count":2}}
            """
            return (Data(payload.utf8), response)
        }
        let start = ContinuousClock.now
        let response = try await CodexOAuthUsageFetcher.fetchUsage(
            accessToken: "invented-token", accountId: nil,
            env: ["CODEX_HOME": "/nonexistent-invented-codex-home"], session: transport)
        #expect(start.duration(to: .now) < .seconds(10))
        #expect(response.rateLimit?.primaryWindow?.usedPercent == 32)
        #expect(response.resetCredits?.availableCount == 2)
        #expect(response.resetCredits?.credits == nil)
        #expect(await transport.requests().count == 2)
    }

    @Test
    func customBaseURLSkipsDetails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "chatgpt_base_url = \"https://example.invalid\"".write(
            to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.path == "/api/codex/usage")
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"rate_limit_reset_credits":{"available_count":2}}"#.utf8), response)
        }
        let response = try await CodexOAuthUsageFetcher.fetchUsage(
            accessToken: "invented-token", accountId: nil,
            env: ["CODEX_HOME": root.path], session: transport)
        #expect(response.resetCredits?.availableCount == 2)
        #expect(await transport.requests().count == 1)
    }

    @Test
    func statusCasingAndUnusableDetailsPreserveCount() throws {
        for status in ["AVAILABLE", "Available", "available"] {
            let credits = try self.decode("{\"available_count\":0,\"credits\":[{\"status\":\"\(status)\"}]}")
            let presentation = CodexResetCreditsContent.Presentation.make(
                credits: credits, weeklyUsedPercent: nil, now: .now)
            #expect(presentation.count == 1)
            #expect(presentation.expiryLines.count == 1)
        }
        for details in ["[]", "[42]", "[{}]", #"[{"status":"unknown"}]"#] {
            let credits = try self.decode("{\"available_count\":3,\"credits\":\(details)}")
            #expect(CodexResetCreditsContent.Presentation.make(
                credits: credits, weeklyUsedPercent: nil, now: .now).count == 3)
        }
        let spent = try self.decode(#"{"available_count":3,"credits":[{"status":"REDEEMED"}]}"#)
        #expect(CodexResetCreditsContent.Presentation.make(
            credits: spent, weeklyUsedPercent: nil, now: .now).count == 0)
    }

    @Test
    func sameDayExpiryUsesLocalTodayOrTonight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 2 * 3600))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-06T00:00:00Z"))
        for (time, label) in [("07:00", "09:00 today"), ("15:59", "17:59 today"),
                              ("16:00", "18:00 tonight"), ("21:21", "23:21 tonight")]
        {
            let credits = try self.decode("""
            {"credits":[{"status":"available","expires_at":"2026-11-06T\(time):00Z"}]}
            """)
            let presentation = CodexResetCreditsContent.Presentation.make(
                credits: credits, weeklyUsedPercent: 32, now: now, calendar: calendar)
            #expect(presentation.warning?.contains("Reset expires \(label).") == true)
        }
    }

    @Test
    func weeklyOnlyOAuthSnapshotRetainsResetsThroughCopiesAndPersistence() throws {
        let json = """
        {"rate_limit":{"primary_window":{"used_percent":32,"reset_at":1794007260,
        "limit_window_seconds":604800},"secondary_window":null},
        "rate_limit_reset_credits":\(Self.fixture)}
        """
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        let credentials = CodexOAuthCredentials(
            accessToken: "invented-token", refreshToken: "", idToken: nil, accountId: nil, lastRefresh: nil)
        let state = try #require(CodexReconciledState.fromOAuth(response: response, credentials: credentials))
        let snapshot = state.toUsageSnapshot()
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 32)
        #expect(snapshot.codexResetCredits?.availableCount == 3)
        let copy = snapshot.withIdentity(snapshot.identity).with(extraRateWindows: [])
        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(copy))
        #expect(restored.codexResetCredits?.credits?.count == 5)
        #expect(restored.codexResetCredits?.credits?.first?.expiresAt ==
            snapshot.codexResetCredits?.credits?.first?.expiresAt)
    }

    @Test
    func countdownAndBurnWarningRespectBoundaries() throws {
        let expiry = Date(timeIntervalSince1970: 1_794_007_260)
        let now = expiry.addingTimeInterval(-14 * 3600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let credits = try self.decode()
        let presentation = CodexResetCreditsContent.Presentation.make(
            credits: credits, weeklyUsedPercent: 32, now: now, calendar: calendar)
        #expect(presentation.count == 3)
        #expect(presentation.expiryLines.first == "Full reset 1: in 14h")
        #expect(presentation.expiryLines.last == "Full reset 3: Does not expire")
        #expect(presentation.warning ==
            "Reset expires 23:21 tonight. 68% unused. Burn about 4.9%/h, then redeem it yourself.")
        for used: Double? in [95, 100, nil, .nan] {
            #expect(CodexResetCreditsContent.Presentation.make(
                credits: credits, weeklyUsedPercent: used, now: now, calendar: calendar).warning == nil)
        }
        #expect(CodexResetCreditsContent.Presentation.make(
            credits: credits, weeklyUsedPercent: 32, now: expiry.addingTimeInterval(-86401),
            calendar: calendar).warning == nil)
        #expect(CodexResetCreditsContent.Presentation.make(
            credits: credits, weeklyUsedPercent: 32, now: expiry, calendar: calendar).count == 2)
        let noExpiry = try self.decode(#"{"credits":[{"status":"available"}]}"#)
        #expect(CodexResetCreditsContent.Presentation.make(
            credits: noExpiry, weeklyUsedPercent: 32, now: now, calendar: calendar).warning == nil)
    }

    @Test
    func weeklyOnlyCardHasNoEmptySessionBar() throws {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 32, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            codexResetCredits: try self.decode(),
            updatedAt: now)
        let projection = CodexConsumerProjection.make(
            surface: .liveCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot, rawUsageError: nil, liveCredits: nil, rawCreditsError: nil,
                liveDashboard: nil, rawDashboardError: nil, dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false, now: now))
        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: try #require(ProviderDefaults.metadata[.codex]),
            snapshot: snapshot, codexProjection: projection,
            credits: nil, creditsError: nil, dashboard: nil, dashboardError: nil,
            tokenSnapshot: nil, tokenError: nil, account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false, lastError: nil, usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown, tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false, hidePersonalInfo: false, now: now))
        #expect(model.metrics.map(\.id) == ["secondary"])
        #expect(model.resetCredits?.availableCount == 3)
        #expect(model.resetCreditsWeeklyUsedPercent == 32)
        #expect(model.hasUsageContent)
    }

    @Test
    func emptyResetSummaryDoesNotChangeErrorOnlyCard() throws {
        for summary in ["{}", #"{"available_count":0}"#, #"{"available_count":0,"credits":[]}"#] {
            let credits = try self.decode(summary)
            let snapshot = UsageSnapshot(primary: nil, secondary: nil, codexResetCredits: credits, updatedAt: .now)
            var model = UsageMenuCardView.Model.make(.init(
                provider: .codex,
                metadata: try #require(ProviderDefaults.metadata[.codex]),
                snapshot: snapshot,
                credits: nil, creditsError: nil, dashboard: nil, dashboardError: nil,
                tokenSnapshot: nil, tokenError: nil, account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false, lastError: "Invented usage failure", usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown, tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: false, hidePersonalInfo: false, now: .now))
            #expect(model.resetCredits == nil)
            #expect(model.isOverviewErrorOnly)
            #expect(!model.hasUsageContent)
            // Direct model updates must classify empty summaries the same way.
            model.resetCredits = credits
            #expect(model.isOverviewErrorOnly)
            #expect(!model.hasUsageContent)
        }
    }

    @Test
    func warningAppearanceChangesTrackedLayout() throws {
        let now = Date.now
        let expiry = now.addingTimeInterval(3600).timeIntervalSince1970
        let credits = try self.decode("""
        {"available_count":1,"credits":[{"status":"available","expires_at":\(expiry)}]}
        """)
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, codexResetCredits: credits, updatedAt: now)
        var model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: try #require(ProviderDefaults.metadata[.codex]), snapshot: snapshot,
            credits: nil, creditsError: nil, dashboard: nil, dashboardError: nil,
            tokenSnapshot: nil, tokenError: nil, account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false, lastError: nil, usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown, tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false, hidePersonalInfo: false, now: now))
        model.resetCreditsWeeklyUsedPercent = 95
        var candidate = model
        candidate.resetCreditsWeeklyUsedPercent = 32
        #expect(model.hasCompatibleTrackedLayout(with: model))
        #expect(!model.hasCompatibleTrackedLayout(with: candidate))
        #expect(!candidate.hasCompatibleTrackedLayout(with: model))
    }

    @Test
    func zeroCountAndInlineDetailsDoNotFetchAgain() async throws {
        for summary in [#"{"available_count":0}"#, Self.fixture] {
            let transport = ProviderHTTPTransportStub { request in
                let url = try #require(request.url)
                #expect(url.path.hasSuffix("/usage"))
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data("{\"rate_limit_reset_credits\":\(summary)}".utf8), response)
            }
            _ = try await CodexOAuthUsageFetcher.fetchUsage(
                accessToken: "invented-token", accountId: nil,
                env: ["CODEX_HOME": "/nonexistent-invented-codex-home"], session: transport)
            #expect(await transport.requests().count == 1)
        }
    }

    @Test
    func productionSourcesNeverContainResetConsumptionPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))
        let sourceExtensions: Set = ["swift", "m", "mm", "h", "c", "cpp", "rs", "py", "sh", "js", "ts"]
        let forbidden = ["rate-limit-reset-credits", "consume"].joined(separator: "/")
        for case let file as URL in files {
            guard sourceExtensions.contains(file.pathExtension),
                  (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                  let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            #expect(!contents.contains(forbidden), "Forbidden reset consumption path in \(file.lastPathComponent)")
        }
    }
}

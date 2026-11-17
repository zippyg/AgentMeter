import CryptoKit
import Foundation
import Testing
@testable import AgentMeter
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeLimitResetsTests {
    // Invented grants following the 2.1.322 bundle schema. Real unavailable responses are a separate fixture.
    static let grants = #"{"cedar_ember":{"eligible":true,"grants":[{"id":"invented-grant","label":"Fable","resets_left":2,"ends_at":"2026-11-30T19:54:00Z","clears":["seven_day_overage_included"],"gives_back_weekly":true,"paused":false},{"label":"Full","resets_left":1,"ends_at":"2026-12-01T22:28:00.000Z","clears":["five_hour","seven_day"],"type":"full"}]}}"#
    let now = ISO8601DateFormatter().date(from: "2026-11-11T12:00:00Z")!

    @Test func parsesKindsCountsExpiryAndRoundTripWithoutIDs() throws {
        let resets = try #require(try ClaudeLimitResets.decodeUsage(Data(Self.grants.utf8)))
        #expect(resets.count(at: self.now) == 3)
        #expect(resets.grants.map(\.kind) == ["Fable reset", "Full reset"])
        #expect(resets.grants.allSatisfy { $0.expiresAt != nil })
        let data = try JSONEncoder().encode(resets)
        #expect(!String(decoding: data, as: UTF8.self).contains("invented-grant"))
        #expect(try JSONDecoder().decode(ClaudeLimitResets.self, from: data) == resets)
        #expect(resets.count(at: self.now.addingTimeInterval(30 * 86400)) == 0)
    }

    @Test func missingAndUnavailableAreUnknownWhileExplicitZeroIsNone() throws {
        #expect(try ClaudeLimitResets.decodeUsage(Data("{}".utf8)) == nil)
        #expect(try ClaudeLimitResets.decodeUsage(Data(#"{"cedar_ember":null}"#.utf8)) == nil)
        let url = try #require(Bundle.module.url(forResource: "claude-limit-resets-unavailable-2026-11-11",
                                                 withExtension: "json", subdirectory: "Fixtures"))
        let responses = try JSONDecoder().decode([String: [String: ClaudeLimitResetsUnavailable]].self,
                                                 from: Data(contentsOf: url))
        #expect(responses.count == 2)
        for response in responses.values {
            let data = try JSONEncoder().encode(response)
            #expect(throws: (any Error).self) { try ClaudeLimitResets.decodeUsage(data) }
        }
        let zero = try #require(try ClaudeLimitResets.decodeUsage(Data(
            #"{"cedar_ember":{"eligible":false,"ineligible_reason":"no_grant","grants":[]}}"#.utf8)))
        #expect(zero.count(at: self.now) == 0)
        #expect(throws: (any Error).self) {
            try ClaudeLimitResets.decodeUsage(Data(#"{"cedar_ember":{"eligible":true}}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try ClaudeLimitResets.decodeUsage(Data(Self.grants.replacingOccurrences(of: "\"resets_left\":2",
                                                                                  with: "\"resets_left\":-1").utf8))
        }
    }

    @Test func unknownKindIsExplicitAndNoExpiryIsPreserved() throws {
        let data = Data(#"{"cedar_ember":{"grants":[{"label":"Invented","resets_left":1,"clears":[],"type":"invented"}]}}"#.utf8)
        let resets = try #require(try ClaudeLimitResets.decodeUsage(data))
        #expect(resets.grants[0].kind == "Invented")
        #expect(resets.grants[0].expiresAt == nil)
        #expect(resets.count(at: self.now) == 1)
        let sparse = try #require(try ClaudeLimitResets.decodeUsage(Data(
            #"{"cedar_ember":{"grants":[{"resets_left":2}]}}"#.utf8)))
        #expect(sparse.grants[0].kind == "Unknown reset")
        #expect(sparse.count(at: self.now) == 2)
    }

    @MainActor @Test func groupsPerLoginKeepsExpiryAndHidesNames() throws {
        var first = UsagePoolForecast.Account(id: "claude:cswap:1", displayName: "Work-1", weekly: nil)
        first.claudeLimitResets = try ClaudeLimitResets.decodeUsage(Data(Self.grants.utf8))
        var zero = UsagePoolForecast.Account(id: "claude:cswap:2", displayName: "Personal", weekly: nil)
        zero.claudeLimitResets = try ClaudeLimitResets.decodeUsage(Data(
            #"{"cedar_ember":{"eligible":true,"grants":[]}}"#.utf8))
        let unknown = UsagePoolForecast.Account(id: "claude:cswap:3", displayName: "Work-2", weekly: nil)
        let state = UsagePoolPresentation()
        state.update(accounts: [first, zero, unknown], codex: nil, sources: [], now: self.now)
        let rows = try #require(state.model.claudeBankedResets(first))
        #expect(rows.map(\.number) == [1, 2, 3])
        #expect(rows.map(\.kind) == ["Fable reset", "Fable reset", "Full reset"])
        #expect(rows[0].expiresAt == rows[1].expiresAt)
        #expect(rows[0].expiresAt! < rows[2].expiresAt!)
        #expect(state.model.claudeBankedResets(zero)?.count == 0)
        #expect(state.model.claudeBankedResets(unknown)?.count == nil)
        #expect(state.model.claudeBankedResetTotal == "3+")
        state.hideNames = true
        #expect(state.accounts.enumerated().map { state.name($0.element, index: $0.offset) }
            == ["Login 1", "Login 2", "Login 3"])
    }

    @Test func refreshUsesOnlyOptInGETCachesSeparatelyAndRejectsReplacedSlots() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".claude-swap-backup")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sequence = root.appendingPathComponent("sequence.json")
        try Data(#"{"accounts":{"1":{"email":"invented-one@example.invalid"},"2":{"email":"invented-two@example.invalid"}}}"#.utf8).write(to: sequence)
        let recorder = ResetRequests()
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/api/oauth/usage")
            #expect(request.url?.query == "cedar_ember=1&skip_spend=1")
            #expect(request.value(forHTTPHeaderField: "x-app") == "cli")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.322 (external, cli)")
            let bearer = request.value(forHTTPHeaderField: "Authorization")
            await recorder.record()
            let body = bearer == "Bearer invented-slot-1" ? Self.grants
                : #"{"cedar_ember":{"eligible":true,"grants":[]}}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                   httpVersion: nil, headerFields: nil)!)
        }
        await ClaudeSwapLimitResets.refresh(home: home, now: self.now,
                                            token: { "invented-slot-\($0.slot)" }, transport: transport)
        let cache = ClaudeSwapLimitResets.cached(home: home, now: self.now)
        #expect(cache["claude:cswap:1"]?.count(at: self.now) == 3)
        #expect(cache["claude:cswap:2"]?.count(at: self.now) == 0)
        await ClaudeSwapLimitResets.refresh(home: home, now: self.now.addingTimeInterval(60),
                                            token: { "invented-slot-\($0.slot)" }, transport: transport)
        #expect(await recorder.count == 2)
        let persisted = try String(contentsOf: ClaudeSwapLimitResets.cacheURL(home: home), encoding: .utf8)
        #expect(!persisted.contains("@"))
        #expect(!persisted.contains("Bearer"))
        #expect(!persisted.contains("invented-grant"))
        #expect(ClaudeSwapLimitResets.cached(home: home, now: self.now.addingTimeInterval(901)).count == 2)
        try Data(#"{"accounts":{"1":{"email":"invented-new@example.invalid"}}}"#.utf8).write(to: sequence)
        #expect(ClaudeSwapLimitResets.cached(home: home, now: self.now).isEmpty)
    }
    private func fixtureHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent(".claude-swap-backup")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"accounts":{"1":{"email":"invented@example.invalid","organizationUuid":"invented-org"}}}"#.utf8)
            .write(to: root.appendingPathComponent("sequence.json"))
        return home
    }

    private var success: ProviderHTTPTransportHandler {
        ProviderHTTPTransportHandler { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            return (Data(Self.grants.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                          httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func accessTokenSourcesIdentityAndExpiry() throws {
        let home = try self.fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let login = try #require(ClaudeSwapLimitResets.logins(home: home).first)
        let root = home.appendingPathComponent(".claude-swap-backup")
        let profile = root.appendingPathComponent("sessions/1-invented_example.invalid")
        let credentials = root.appendingPathComponent("credentials")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        func data(_ source: String, expired: Bool = false) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
                "accessToken": source, "expiresAt": self.now.addingTimeInterval(expired ? -1 : 3600)
                    .timeIntervalSince1970 * 1000]])
        }
        let backup = credentials.appendingPathComponent(".creds-1-invented@example.invalid.enc")
        try data("invented-backup").base64EncodedData().write(to: backup)
        let config = profile.appendingPathComponent(".claude.json")
        try Data(#"{"oauthAccount":{"emailAddress":"invented@example.invalid","organizationUuid":"invented-org"}}"#.utf8)
            .write(to: config)
        try data("invented-file").write(to: profile.appendingPathComponent(".credentials.json"))
        let keychainData = try data("invented-profile-keychain")
        let profileToken = ClaudeSwapLimitResets.accessToken(login, home: home, now: self.now, keychain: { service, account in
            let digest = SHA256.hash(data: Data(profile.path.precomposedStringWithCanonicalMapping.utf8))
                .map { String(format: "%02x", $0) }.joined().prefix(8)
            #expect(service == "Claude Code-credentials-\(digest)")
            #expect(account == NSUserName())
            return keychainData
        })
        #expect(profileToken == "invented-profile-keychain")
        #expect(ClaudeSwapLimitResets.accessToken(login, home: home, now: self.now, keychain: { _, _ in nil })
            == "invented-file")
        // A profile from another identity must never supply credentials, even from its keychain.
        try Data(#"{"oauthAccount":{"emailAddress":"other@example.invalid","organizationUuid":"invented-org"}}"#.utf8)
            .write(to: config)
        #expect(ClaudeSwapLimitResets.accessToken(login, home: home, now: self.now, keychain: { _, _ in
            Issue.record("Backup file must win without keychain access")
            return nil
        }) == "invented-backup")
        try FileManager.default.removeItem(at: backup)
        let fallback = try data("invented-keychain-fallback")
        let fallbackToken = ClaudeSwapLimitResets.accessToken(login, home: home, now: self.now, keychain: { service, account in
            #expect(service == "claude-swap")
            #expect(account == "account-1-invented@example.invalid")
            return fallback
        })
        #expect(fallbackToken == "invented-keychain-fallback")
        let expired = try data("invented-expired", expired: true)
        #expect(ClaudeSwapLimitResets.accessToken(login, home: home, now: self.now, keychain: { _, _ in expired }) == nil)
        try Data(#"{"oauthAccount":{"emailAddress":"invented@example.invalid","organizationUuid":"wrong-org"}}"#.utf8)
            .write(to: config)
        #expect(ClaudeSwapLimitResets.accessToken(login, home: home, now: self.now, keychain: { _, _ in nil }) == nil)
    }

    @Test(arguments: [401, 403, 429, -1, -2, 200])
    func failuresKeepLastGoodWithAge(kind: Int) async throws {
        let home = try self.fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        await ClaudeSwapLimitResets.refresh(home: home, now: self.now, token: { _ in "fixture-token" }, transport: self.success)
        let later = self.now.addingTimeInterval(2 * 3600)
        let failure = ProviderHTTPTransportHandler { request in
            if kind == -1 { throw URLError(.timedOut) }
            if kind == -2 { throw CancellationError() }
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: kind,
                httpVersion: nil, headerFields: ["Retry-After": "10800"])!)
        }
        await ClaudeSwapLimitResets.refresh(home: home, now: later, token: { _ in "fixture-token" }, transport: failure)
        let reading = try #require(ClaudeSwapLimitResets.cached(home: home, now: later)["claude:cswap:1"])
        #expect(reading.count(at: later) == 3)
        #expect(reading.age(at: later) == "as of 2h ago")
        let persisted = try #require(ClaudeSwapLimitResets.readings(home: home)["1"])
        #expect(persisted.fetchedAt == self.now)
        #expect(persisted.attemptedAt == later)
        if kind > 0 && kind != 200 { #expect(persisted.nextAttemptAt == later.addingTimeInterval(10800)) }
        #expect(ClaudeSwapLimitResets.cached(home: home, now: self.now.addingTimeInterval(7 * 86400)).count == 1)
        #expect(ClaudeSwapLimitResets.cached(home: home, now: self.now.addingTimeInterval(7 * 86400 + 1)).isEmpty)
    }

    @Test func cadenceBackoffAndSuccessReset() async throws {
        let home = try self.fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let recorder = ResetRequests()
        let failed = ProviderHTTPTransportHandler { request in
            await recorder.record()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        var now = self.now
        for hours in [2, 4, 8, 12, 12] {
            await ClaudeSwapLimitResets.refresh(home: home, now: now, manual: true,
                                                token: { _ in "fixture-token" }, transport: failed)
            let reading = try #require(ClaudeSwapLimitResets.readings(home: home)["1"])
            #expect(reading.nextAttemptAt == now.addingTimeInterval(Double(hours * 3600)))
            let before = await recorder.count
            await ClaudeSwapLimitResets.refresh(home: home, now: now.addingTimeInterval(Double(hours * 3600 - 1)),
                manual: true, token: { _ in "fixture-token" }, transport: failed)
            #expect(await recorder.count == before)
            now = try #require(reading.nextAttemptAt)
        }
        await ClaudeSwapLimitResets.refresh(home: home, now: now, token: { _ in "fixture-token" }, transport: self.success)
        #expect(ClaudeSwapLimitResets.readings(home: home)["1"]?.failures == 0)
        #expect(ClaudeSwapLimitResets.readings(home: home)["1"]?.nextAttemptAt == nil)
        // Automatic reads wait 45 minutes; manual reads require strictly more than five minutes.
        await ClaudeSwapLimitResets.refresh(home: home, now: now.addingTimeInterval(44 * 60),
            token: { _ in "fixture-token" }, transport: failed)
        #expect(await recorder.count == 5)
        await ClaudeSwapLimitResets.refresh(home: home, now: now.addingTimeInterval(5 * 60), manual: true,
            token: { _ in "fixture-token" }, transport: failed)
        #expect(await recorder.count == 5)
        await ClaudeSwapLimitResets.refresh(home: home, now: now.addingTimeInterval(5 * 60 + 1), manual: true,
            token: { _ in "fixture-token" }, transport: failed)
        #expect(await recorder.count == 6)
    }

    @Test func newTokenClearsBackoff() async throws {
        let home = try self.fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let recorder = ResetRequests()
        let failed = ProviderHTTPTransportHandler { request in
            await recorder.record()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        await ClaudeSwapLimitResets.refresh(home: home, now: self.now, token: { _ in "stale-token" }, transport: failed)
        #expect(await recorder.count == 1)
        // Same token during backoff: no request.
        await ClaudeSwapLimitResets.refresh(home: home, now: self.now.addingTimeInterval(3600), manual: true,
            token: { _ in "stale-token" }, transport: failed)
        #expect(await recorder.count == 1)
        // After a re-login the new token is tried at once and its success clears the backoff.
        await ClaudeSwapLimitResets.refresh(home: home, now: self.now.addingTimeInterval(3600), manual: true,
            token: { _ in "fresh-token" }, transport: self.success)
        let reading = try #require(ClaudeSwapLimitResets.readings(home: home)["1"])
        #expect(reading.failures == 0)
        #expect(reading.nextAttemptAt == nil)
        #expect(reading.tokenFingerprint == ClaudeSwapLimitResets.fingerprint("fresh-token"))
        #expect(reading.tokenFingerprint?.contains("fresh") == false)
    }

    @Test func automaticCadenceConcurrentLoginsAndExpiredTokenSkip() async throws {
        let home = try self.fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"accounts":{"1":{"email":"invented-one@example.invalid"},"2":{"email":"invented-two@example.invalid"},"3":{"email":"invented-expired@example.invalid"}}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude-swap-backup/sequence.json"))
        let recorder = ConcurrentResetRequests()
        let transport = ProviderHTTPTransportHandler { request in
            await recorder.enter()
            try await Task.sleep(for: .milliseconds(20))
            await recorder.leave()
            return (Data(Self.grants.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                          httpVersion: nil, headerFields: nil)!)
        }
        let expired = Data(#"{"claudeAiOauth":{"accessToken":"invented-expired","expiresAt":1}}"#.utf8)
        let now = self.now
        let tokens: @Sendable (ClaudeSwapLimitResets.Login) -> String? = { login in
            if login.slot == "3" {
                return ClaudeSwapLimitResets.accessToken(login, home: home, now: now, keychain: { _, _ in expired })
            }
            return "invented-slot-\(login.slot)"
        }
        await ClaudeSwapLimitResets.refresh(home: home, now: now, token: tokens, transport: transport)
        #expect(await recorder.maximum == 2)
        #expect(await recorder.count == 2)
        #expect(ClaudeSwapLimitResets.cached(home: home, now: now)["claude:cswap:3"] == nil)
        await ClaudeSwapLimitResets.refresh(home: home, now: now.addingTimeInterval(45 * 60 - 1),
                                            token: tokens, transport: transport)
        #expect(await recorder.count == 2)
        await ClaudeSwapLimitResets.refresh(home: home, now: now.addingTimeInterval(45 * 60),
                                            token: tokens, transport: transport)
        #expect(await recorder.count == 4)
    }

    @Test func cancellationDoesNotOverwriteOrThrottleGoodReading() async throws {
        let home = try self.fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        await ClaudeSwapLimitResets.refresh(home: home, now: self.now, token: { _ in "fixture-token" }, transport: self.success)
        let before = try Data(contentsOf: ClaudeSwapLimitResets.cacheURL(home: home))
        let transport = ProviderHTTPTransportHandler { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        let task = Task {
            await ClaudeSwapLimitResets.refresh(home: home, now: self.now.addingTimeInterval(3600),
                token: { _ in "fixture-token" }, transport: transport)
        }
        await task.value
        #expect(try Data(contentsOf: ClaudeSwapLimitResets.cacheURL(home: home)) == before)
    }

    @MainActor @Test func labelsAvailabilityExpiryAndRowLimit() throws {
        let payload = #"{"cedar_ember":{"grants":[{"label":"API label","type":"new-kind","gives_back_weekly":true,"resets_left":1},{"label":"Full","type":"full","resets_left":2,"paused":true},{"label":"Later","resets_left":1,"starts_at":"2026-11-12T00:00:00Z"},{"label":"Unavailable","resets_left":1,"usable_now":false},{"label":"Expired","resets_left":9,"ends_at":"2026-11-11T12:00:00Z"},{"label":"Fable Full","type":"full","resets_left":1},{"label":"Type label","type":"fable_full","resets_left":1},{"label":"Safe label","type":"unsafe@type","resets_left":1}]}}"#
        let resets = try #require(try ClaudeLimitResets.decodeUsage(Data(payload.utf8)))
        #expect(resets.count(at: self.now) == 4)
        #expect(resets.available(at: self.now).count == 7)
        #expect(resets.grants.map(\.kind) == ["API label", "Full reset", "Later", "Unavailable", "Expired", "Fable reset", "Fable reset", "Safe label"])
        #expect(resets.grants[0].givesBackWeekly == true)
        var account = UsagePoolForecast.Account(id: "claude:cswap:1", displayName: "Invented", weekly: nil)
        account.claudeLimitResets = resets
        let state = UsagePoolPresentation()
        state.update(accounts: [account], codex: nil, sources: [], now: self.now)
        #expect(state.model.claudeBankedResetTotal == "4 · 4 not usable")
        #expect(state.model.claudeBankedResets(account)?.compactMap(\.availability).sorted()
            == ["Not yet usable", "Not yet usable", "Paused", "Paused"])
        account.claudeLimitResets = try ClaudeLimitResets.decodeUsage(Data(
            #"{"cedar_ember":{"grants":[{"resets_left":1000}]}}"#.utf8))
        state.update(accounts: [account], codex: nil, sources: [], now: self.now)
        #expect(state.model.claudeBankedResetTotal == "1000")
        #expect(state.model.claudeBankedResets(account)?.count == 20)
        #expect(state.model.claudeResetDetail(account) == "980 more")
        account.claudeLimitResets?.fetchedAt = self.now.addingTimeInterval(-7 * 86400 - 1)
        state.update(accounts: [account], codex: nil, sources: [], now: self.now)
        #expect(state.model.claudeBankedResetTotal == "Unknown")
        #expect(state.model.claudeBankedResets(account)?.count == nil)
        let unsafe = try #require(try ClaudeLimitResets.decodeUsage(Data(
            #"{"cedar_ember":{"grants":[{"label":"unsafe@example.invalid","type":"unsafe@type","resets_left":1}]}}"#.utf8)))
        #expect(unsafe.grants[0].kind == "Unknown reset")

    }

}

private struct ClaudeLimitResetsUnavailable: Codable { let eligible: Bool; let ineligible_reason: String; let grants: [String] }
private actor ResetRequests {
    var count = 0
    func record() { self.count += 1 }
}

private actor ConcurrentResetRequests {
    var count = 0
    var maximum = 0
    private var active = 0
    func enter() {
        self.count += 1
        self.active += 1
        self.maximum = max(self.maximum, self.active)
    }
    func leave() { self.active -= 1 }
}

import CryptoKit
import Foundation
#if os(macOS)
import Security
#endif

/// Supplements cswap's window cache with opt-in grant data. Never refreshes OAuth or redeems grants.
public enum ClaudeSwapLimitResets {
    struct Login: Sendable {
        let slot: String
        let email: String
        let identity: String
        let organization: String
    }

    struct Reading: Codable, Sendable {
        let identity: String
        let fetchedAt: Date
        let attemptedAt: Date
        let resets: ClaudeLimitResets?
        let failed: Bool
        var failures: Int? = nil
        var nextAttemptAt: Date? = nil
        var failureKind: String? = nil
        /// Truncated SHA-256 of the token used, so a re-login clears an old backoff.
        var tokenFingerprint: String? = nil
    }

    static func fingerprint(_ token: String?) -> String? {
        token.map { SHA256.hash(data: Data($0.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() }
    }

    static func logins(home: URL) -> [Login] {
        let path = home.appendingPathComponent(".claude-swap-backup/sequence.json")
        guard let data = try? Data(contentsOf: path), data.count < 2 * 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["accounts"] as? [String: [String: Any]], accounts.count <= 64 else { return [] }
        return accounts.keys.sorted().compactMap { slot in
            guard let number = Int(slot), number > 0, String(number) == slot,
                  let metadata = accounts[slot], let email = metadata["email"] as? String,
                  !email.contains("/"), !email.contains("\\"),
                  let identity = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) else { return nil }
            return Login(slot: slot, email: email,
                         identity: SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined(),
                         organization: metadata["organizationUuid"] as? String ?? "")
        }
    }

    static func cacheURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Caches/com.zain.agentmeter.menu/claude-limit-resets.json")
    }

    static func readings(home: URL) -> [String: Reading] {
        guard let data = try? Data(contentsOf: self.cacheURL(home: home)), data.count <= 2 * 1024 * 1024 else { return [:] }
        return (try? JSONDecoder().decode([String: Reading].self, from: data)) ?? [:]
    }

    public static func cached(home: URL, now: Date) -> [String: ClaudeLimitResets] {
        let readings = self.readings(home: home)
        return Dictionary(uniqueKeysWithValues: self.logins(home: home).compactMap { login in
            guard let reading = readings[login.slot], reading.identity == login.identity,
                  now.timeIntervalSince(reading.fetchedAt) >= 0,
                  now.timeIntervalSince(reading.fetchedAt) <= 7 * 86400, var resets = reading.resets else { return nil }
            resets.fetchedAt = reading.fetchedAt
            return ("claude:cswap:\(login.slot)", resets)
        })
    }

    private static let refreshGate = RefreshGate()
    private static let grantTransport: ProviderHTTPClient = {
        let configuration = ProviderHTTPClient.defaultConfiguration()
        configuration.urlCache = nil
        return ProviderHTTPClient(session: ProviderHTTPClient.redirectGuardedSession(configuration: configuration))
    }()

    public static func refresh(home: URL, now: Date = Date(), manual: Bool = false) async {
        await self.refresh(home: home, now: now, manual: manual,
                           token: { self.accessToken($0, home: home, now: now) }, transport: self.grantTransport)
    }

    static func refresh(
        home: URL, now: Date, manual: Bool = false,
        token: @escaping @Sendable (Login) -> String?, transport: any ProviderHTTPTransport) async
    {
        guard await self.refreshGate.begin(home.path) else { return }
        await self.fetchReadings(home: home, now: now, manual: manual, token: token, transport: transport)
        await self.refreshGate.end(home.path)
    }

    private static func fetchReadings(
        home: URL, now: Date, manual: Bool,
        token: @escaping @Sendable (Login) -> String?, transport: any ProviderHTTPTransport) async
    {
        var readings = self.readings(home: home)
        let logins = self.logins(home: home)
        readings = readings.filter { slot, reading in
            logins.contains { $0.slot == slot && $0.identity == reading.identity }
        }
        await withTaskGroup(of: (String, Reading)?.self) { group in
            for login in logins {
                let previous = readings[login.slot]
                let accessToken = token(login)
                let fingerprint = self.fingerprint(accessToken)
                // A new token (re-login) skips any backoff or interval earned by the old one.
                if let previous, previous.tokenFingerprint == fingerprint {
                    if let next = previous.nextAttemptAt, next > now { continue }
                    let interval: TimeInterval = manual ? 5 * 60 : 45 * 60
                    let elapsed = now.timeIntervalSince(previous.attemptedAt)
                    if manual ? elapsed <= interval : elapsed < interval { continue }
                }
                guard !Task.isCancelled else { break }
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    var reading = Reading(identity: login.identity, fetchedAt: previous?.fetchedAt ?? now,
                                          attemptedAt: now, resets: previous?.resets, failed: true,
                                          failures: previous?.failures, tokenFingerprint: fingerprint)
                    do {
                        guard let accessToken else {
                            reading.failureKind = "credentials"
                            return (login.slot, reading)
                        }
                        let response = try await ClaudeOAuthUsageFetcher.fetchUsage(
                            accessToken: accessToken, includeLimitResets: true, detectClaudeVersion: false,
                            now: now, transport: transport)
                        try Task.checkCancellation()
                        guard let resets = response.limitResets else {
                            reading.failureKind = "unavailable"
                            return (login.slot, reading)
                        }
                        reading = Reading(identity: login.identity, fetchedAt: now, attemptedAt: now,
                                          resets: resets, failed: false, failures: 0, tokenFingerprint: fingerprint)
                    } catch {
                        guard !Task.isCancelled else { return nil }
                        reading.failureKind = "network"
                        if let failure = error as? ClaudeGrantRequestError {
                            let failures = min((previous?.failures ?? 0) + 1, 4)
                            reading.failures = failures
                            reading.failureKind = "http\(failure.status)"
                            let delay = min(2 * 3600 * pow(2, Double(failures - 1)), 12 * 3600)
                            reading.nextAttemptAt = max(now.addingTimeInterval(delay), failure.retryAfter ?? now)
                        } else if case let ClaudeOAuthFetchError.rateLimited(retryAfter) = error {
                            let failures = min((previous?.failures ?? 0) + 1, 4)
                            reading.failures = failures
                            reading.failureKind = "http429"
                            reading.nextAttemptAt = max(
                                now.addingTimeInterval(min(2 * 3600 * pow(2, Double(failures - 1)), 12 * 3600)),
                                retryAfter ?? now)
                        }
                    }
                    return (login.slot, reading)
                }
            }
            for await result in group {
                if let (slot, reading) = result { readings[slot] = reading }
            }
        }
        guard !Task.isCancelled else { return }
        // Do not persist a result under a slot that was replaced while its request was in flight.
        let current = self.logins(home: home)
        readings = readings.filter { slot, reading in current.contains { $0.slot == slot && $0.identity == reading.identity } }
        let url = self.cacheURL(home: home)
        guard let data = try? JSONEncoder().encode(readings) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    static func accessToken(
        _ login: Login, home: URL, now: Date = Date(),
        keychain: (String, String) -> Data? = { ClaudeSwapLimitResets.keychain(service: $0, account: $1) }) -> String?
    {
        let root = home.appendingPathComponent(".claude-swap-backup")
        let slug = login.email.precomposedStringWithCanonicalMapping.map { character -> String in
            character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
                ? String(character) : "_"
        }.joined()
        let profile = root.appendingPathComponent("sessions/\(login.slot)-\(slug)")
        let digest = SHA256.hash(data: Data(profile.path.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(8)
        // Profile credentials rotate independently. Match cswap's preference for their latest generation.
        let config = (try? Data(contentsOf: profile.appendingPathComponent(".claude.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let identity = config?["oauthAccount"] as? [String: Any]
        let matches = identity?["emailAddress"] as? String == login.email
            && (login.organization.isEmpty || identity?["organizationUuid"] as? String == login.organization)
        let profileData = matches ? keychain("Claude Code-credentials-\(digest)", NSUserName())
            ?? (try? Data(contentsOf: profile.appendingPathComponent(".credentials.json"))) : nil
        let backupURL = root.appendingPathComponent("credentials/.creds-\(login.slot)-\(login.email).enc")
        let backup = profileData == nil ? (try? String(contentsOf: backupURL, encoding: .utf8))
            .flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? keychain("claude-swap", "account-\(login.slot)-\(login.email)") : nil
        guard let data = profileData ?? backup,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any] else { return nil }
        if let expiresAt = oauth["expiresAt"] as? Double,
           Date(timeIntervalSince1970: expiresAt / 1000) <= now { return nil }
        return oauth["accessToken"] as? String
    }

    // Claude Code rewrites these items on every token refresh, which drops AgentMeter from their
    // access list and re-prompts. /usr/bin/security created them, so reading through it never prompts.
    private static func keychain(service: String, account: String) -> Data? {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : Data(text.utf8)
        #else
        return nil
        #endif
    }
}

private actor RefreshGate {
    private var homes: Set<String> = []
    func begin(_ home: String) -> Bool { self.homes.insert(home).inserted }
    func end(_ home: String) { self.homes.remove(home) }
}

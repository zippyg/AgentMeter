import Foundation

/// Decodes only supplied cache bytes. Does not read disk, poll, switch accounts or retain emails.
public enum UsagePoolClaudeCache {
    public enum CacheError: Error { case invalidCache }

    public static func accounts(
        usage: Data, sequence: Data, umbrella: Data, umbrellaState: Data? = nil, now: Date,
        calibratedCapacities: [String: Double] = [:]) throws -> [UsagePoolForecast.Account]
    {
        guard [usage, sequence, umbrella].allSatisfy({ $0.count <= 2 * 1024 * 1024 }),
              let cache = try? JSONDecoder().decode(Cache.self, from: usage), [1, 2].contains(cache.schemaVersion),
              let sequence = try? JSONDecoder().decode(Sequence.self, from: sequence),
              let umbrella = try? JSONDecoder().decode(Umbrella.self, from: umbrella),
              sequence.accounts.count <= 64, cache.accounts.count <= 64 else { throw CacheError.invalidCache }
        let state: UmbrellaState?
        if let umbrellaState {
            guard umbrellaState.count <= 2 * 1024 * 1024,
                  let decoded = try? JSONDecoder().decode(UmbrellaState.self, from: umbrellaState) else {
                throw CacheError.invalidCache
            }
            state = decoded
        } else { state = nil }
        let keys = Set(sequence.accounts.keys).union(cache.accounts.keys)
        let slots = keys.compactMap(Int.init).sorted()
        guard slots.count == keys.count, slots.allSatisfy({ $0 > 0 }),
              keys.allSatisfy({ String(Int($0) ?? 0) == $0 }) else {
            throw CacheError.invalidCache
        }
        let activeEmail = sequence.activeAccountNumber.flatMap { sequence.accounts[String($0)]?.email }
        let overflowed = umbrella.enabled != false && activeEmail != nil && activeEmail == umbrella.personal
        let chosenWork = state?.chosen_work.flatMap { $0.count == 2 ? $0.first : nil }
        var workNumber = 0
        return slots.map { slot in
            let metadata = sequence.accounts[String(slot)]
            let reading = cache.accounts[String(slot)]
            let personal = umbrella.enabled != false && metadata?.email != nil && metadata?.email == umbrella.personal
            if !personal { workNumber += 1 }
            let fallback = personal ? "Personal" : "Work-\(workNumber)"
            let alias = metadata?.alias?.trimmingCharacters(in: .whitespacesAndNewlines)
            // A misconfigured alias must not expose an email address as a display name.
            let label = alias.flatMap { !$0.isEmpty && !$0.contains("@") ? $0 : nil } ?? fallback
            let id = "claude:cswap:\(slot)"
            let hasError = !(reading?.lastError ?? "").isEmpty
            // Schema 2 advances the row's fetchedAt only on success, including after a later refusal.
            let measuredAt = (reading?.lastGood?.fetchedAt ??
                (cache.schemaVersion == 2 || !hasError ? reading?.fetchedAt : nil))
                .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            let unavailable = measuredAt == nil || reading?.lastGood?.seven_day == nil ||
                hasError
            let scoped = (reading?.lastGood?.scoped ?? []).enumerated().compactMap { index, window -> NamedRateWindow? in
                guard let name = window.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty, let rate = window.rate(minutes: 10080) else { return nil }
                return NamedRateWindow(id: "scoped-\(index)", title: name, window: rate)
            }
            return UsagePoolForecast.Account(
                id: id, displayName: label,
                weekly: reading?.lastGood?.seven_day?.rate(minutes: 10080),
                session: reading?.lastGood?.five_hour?.rate(minutes: 300), scoped: scoped,
                measuredAt: measuredAt,
                refusedSince: unavailable ? reading?.lastAttemptAt.flatMap {
                    $0.isFinite ? Date(timeIntervalSince1970: $0) : nil
                } ?? now.addingTimeInterval(-7 * 86400) : nil,
                isActive: !personal && (overflowed
                    ? chosenWork != nil && metadata?.email == chosenWork
                    : slot == sequence.activeAccountNumber), isPersonal: personal,
                calibratedCapacity: calibratedCapacities[id],
                isRateLimited: reading?.lastError == "http-429",
                // sequence.json's activeAccountNumber is the login claude-swap has signed in now.
                isCurrentLogin: sequence.activeAccountNumber == slot)
        }
    }

    private struct Cache: Decodable {
        let schemaVersion: Int
        let accounts: [String: Reading]
    }
    private struct Reading: Decodable {
        let lastGood: Windows?
        let fetchedAt: Double?
        let lastAttemptAt: Double?
        let lastError: String?

        enum CodingKeys: String, CodingKey { case lastGood, fetchedAt, lastAttemptAt, lastError }
        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            self.lastGood = try? container?.decodeIfPresent(Windows.self, forKey: .lastGood)
            self.fetchedAt = try? container?.decodeIfPresent(Double.self, forKey: .fetchedAt)
            self.lastAttemptAt = try? container?.decodeIfPresent(Double.self, forKey: .lastAttemptAt)
            self.lastError = try? container?.decodeIfPresent(String.self, forKey: .lastError)
        }
    }
    private struct Windows: Decodable {
        let five_hour: Window?
        let seven_day: Window?
        let scoped: [Window]?
        let fetchedAt: Double?

        enum CodingKeys: String, CodingKey { case five_hour, seven_day, scoped, fetchedAt }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.five_hour = try? container.decodeIfPresent(Window.self, forKey: .five_hour)
            self.seven_day = try? container.decodeIfPresent(Window.self, forKey: .seven_day)
            self.scoped = try? container.decodeIfPresent([Window].self, forKey: .scoped)
            self.fetchedAt = try? container.decodeIfPresent(Double.self, forKey: .fetchedAt)
        }
    }
    private struct Window: Decodable {
        let name: String?
        let pct: Double
        let resets_at: String?
        func rate(minutes: Int) -> RateWindow? {
            guard self.pct.isFinite, (0...100).contains(self.pct) else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let reset = self.resets_at.flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            return RateWindow(usedPercent: self.pct, windowMinutes: minutes, resetsAt: reset, resetDescription: nil)
        }
    }
    private struct Sequence: Decodable {
        let activeAccountNumber: Int?
        let accounts: [String: Metadata]
    }
    private struct Metadata: Decodable {
        let email: String?
        let alias: String?
    }
    private struct Umbrella: Decodable {
        let enabled: Bool?
        let personal: String?
    }
    private struct UmbrellaState: Decodable {
        let chosen_work: [String]?
    }
}

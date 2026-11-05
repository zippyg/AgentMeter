import CoreFoundation
import Foundation

/// Sanitized account data only. The feed's email, alias and raw errors never enter exported state.
public enum ClaudeSwapUsage {
    public enum FeedError: Error { case invalidFeed }

    public static func executable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String?
    {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin",
        ]
        return paths.filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0).appendingPathComponent("cswap").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func fetch() async throws -> [AgentMeterProviderSnapshot]? {
        try await self.fetch(binary: self.executable(), timeout: 10)
    }

    static func fetch(binary: String?, timeout: TimeInterval) async throws -> [AgentMeterProviderSnapshot]? {
        guard let binary else { return nil }
        let result = try await SubprocessRunner.run(
            binary: binary,
            arguments: ["list", "--json"],
            environment: self.childEnvironment(),
            timeout: timeout,
            standardInput: FileHandle.nullDevice,
            label: "cswap-list")
        return try self.parse(Data(result.stdout.utf8))
    }

    /// Only what a uv-installed CLI needs to find its home, cache and locale. The app's own
    /// environment can carry tokens; claude-swap reads its credentials itself.
    static func childEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String]
    {
        let keep: Set = [
            "PATH",
            "HOME",
            "USER",
            "LOGNAME",
            "SHELL",
            "TMPDIR",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "XDG_CACHE_HOME",
            "XDG_CONFIG_HOME",
            "XDG_DATA_HOME",
            "UV_CACHE_DIR",
        ]
        return environment.filter { keep.contains($0.key) }
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> [AgentMeterProviderSnapshot] {
        guard data.count <= 2 * 1024 * 1024 else { throw FeedError.invalidFeed }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              self.number(root["schemaVersion"]) == 1,
              root["error"] == nil || root["error"] is NSNull,
              let accounts = root["accounts"] as? [[String: Any]], accounts.count <= 64
        else { throw FeedError.invalidFeed }
        var seen = Set<Int>()
        let activeNumber = self.number(root["activeAccountNumber"])
        let flagged = accounts.filter { self.boolean($0["active"]) == true }
            .compactMap { self.number($0["number"]) }
        let active: Int? = if let activeNumber {
            flagged.isEmpty || flagged == [activeNumber] ? activeNumber : nil
        } else {
            flagged.count == 1 ? flagged.first : nil
        }
        return try accounts.map { account in
            guard let number = self.number(account["number"]), number > 0, seen.insert(number).inserted else {
                throw FeedError.invalidFeed
            }
            let disabled = self.boolean(account["disabled"]) == true
            let hasError = account["usageError"].map { !($0 is NSNull) } ?? false
            let live = account["usageStatus"] as? String == "ok" && !hasError
            let usage = (live ? account["usage"] : account["lastGoodUsage"]) as? [String: Any] ?? [:]
            let fetchedAt = self.date(account[live ? "usageFetchedAt" : "lastGoodFetchedAt"])
            let age = live ? self.nonnegative(account["usageAgeSeconds"]).map { min($0, 100 * 365 * 86400) } : nil
            let measurementDates = [fetchedAt, age.map { now.addingTimeInterval(-$0) }].compactMap(\.self)
            let updatedAt = min(
                measurementDates.min() ??
                    (live ? now : now.addingTimeInterval(-15 * 60)),
                now)
            var windows = ["fiveHour", "sevenDay"].compactMap { key -> AgentMeterUsageWindow? in
                guard let raw = usage[key] as? [String: Any],
                      let percent = self.nonnegative(raw["pct"]) else { return nil }
                let resetsAt = self.date(raw["resetsAt"])
                // A cached reading whose window has since reset says nothing about the new window:
                // show it empty rather than the old figure, which read 95% days after the reset.
                let reset = resetsAt.map { $0 <= now } ?? false
                return AgentMeterUsageWindow(
                    id: key == "fiveHour" ? "session" : "weekly",
                    title: key == "fiveHour" ? "5-hour" : "Weekly",
                    rateWindow: RateWindow(
                        usedPercent: reset ? 0 : percent,
                        windowMinutes: key == "fiveHour" ? 300 : 10080,
                        resetsAt: reset ? nil : resetsAt,
                        resetDescription: reset ? "Reset since last reading" : nil),
                    feedPace: key == "sevenDay" && !reset ? self.pace(raw) : nil)
            }
            // Additive v1 shapes verified in CodexBar upstream e30054646's ClaudeSwapListParser.
            var windowIDs = Set(windows.map(\.id))
            for scope in (usage["scoped"] as? [[String: Any]] ?? []).prefix(64) {
                guard let name = scope["name"] as? String, name.count <= 80,
                      name.range(
                          of: "^(?:Claude )?(?:Sonnet|Opus|Haiku)(?: [0-9]+(?:[.][0-9]+)*)?(?: only)?$",
                          options: [.regularExpression, .caseInsensitive]) != nil,
                      !AgentMeterSnapshotSecurity.containsSensitiveMaterial(Data(name.utf8)),
                      let percent = self.nonnegative(scope["pct"]) else { continue }
                let id = "model:" + name.lowercased()
                guard windowIDs.insert(id).inserted else { continue }
                let resetsAt = self.date(scope["resetsAt"])
                let reset = resetsAt.map { $0 <= now } ?? false
                windows.append(AgentMeterUsageWindow(
                    id: id,
                    title: name,
                    rateWindow: RateWindow(
                        usedPercent: reset ? 0 : percent,
                        windowMinutes: nil,
                        resetsAt: reset ? nil : resetsAt,
                        resetDescription: reset ? "Reset since last reading" : nil),
                    feedPace: reset ? nil : self.pace(scope)))
            }
            let spend: AgentMeterSpendSummary? = (usage["spend"] as? [String: Any]).flatMap { raw in
                guard let used = self.nonnegative(raw["used"]), let limit = self.nonnegative(raw["limit"]),
                      limit > 0 else { return nil }
                let currency = raw["currency"] as? String ?? "USD"
                guard currency.range(of: "^[A-Za-z]{3}$", options: .regularExpression) != nil else { return nil }
                return AgentMeterSpendSummary(
                    used: used,
                    limit: limit,
                    remaining: max(0, limit - used),
                    currencyCode: currency,
                    resetsAt: self.date(raw["resetsAt"]))
            }
            let staleAfter = updatedAt.addingTimeInterval(15 * 60)
            let status: AgentMeterProviderStatus = disabled ? .unavailable : windows
                .isEmpty && spend == nil ? .unavailable :
                (!live || staleAfter <= now) ? .stale : .ok
            return AgentMeterProviderSnapshot(
                id: "claude:cswap:\(number)",
                displayName: "Claude",
                providerID: "claude",
                accountID: "cswap:\(number)",
                isActiveCLI: disabled ? false : active.map { $0 == number },
                accountLabel: ["Account \(number)", self.boolean(account["isOrganization"]).map {
                    $0 ? "Organization" : "Personal"
                }].compactMap(\.self).joined(separator: " · "),
                accountDisplayHint: self.displayHint(account),
                windows: windows,
                spend: spend,
                source: AgentMeterSourceDescriptor(confidence: .local, label: "claude-swap"),
                status: status,
                updatedAt: updatedAt,
                staleAfter: staleAfter,
                lastError: disabled ? "Account disabled in claude-swap." :
                    live ? nil : self.staleReason(account, measuredAt: measurementDates.min(), now: now))
        }
    }

    /// Usage-attribution keys per claude-swap slot: "slot:N" plus the fingerprint of the slot's
    /// account id, read from claude-swap's own account list. Only each account's `uuid` is read.
    public static func accountKeys(
        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Int: [String]]
    {
        let url = home.appendingPathComponent(".claude-swap-backup/sequence.json")
        guard let data = try? Data(contentsOf: url), data.count <= 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["accounts"] as? [String: Any] else { return [:] }
        var keys: [Int: [String]] = [:]
        for (raw, value) in accounts {
            guard let number = Int(raw), number > 0 else { continue }
            var entry = ["slot:\(number)"]
            if let uuid = (value as? [String: Any])?["uuid"] as? String, !uuid.isEmpty {
                entry.append(CostUsageScanner.claudeAccountKey(uuid: uuid))
            }
            keys[number] = entry
        }
        return keys
    }

    /// Why a card shows an old reading, in words: its age and the fetch failure, never raw error text.
    static func staleReason(_ account: [String: Any], measuredAt: Date?, now: Date) -> String {
        let measured = measuredAt ?? self.nonnegative(account["lastGoodAgeSeconds"]).map { now.addingTimeInterval(-$0) }
        let age = measured.map { "Last reading \(self.ageText(now.timeIntervalSince($0))) ago" } ?? "No recent reading"
        let cause: String? = switch account["usageError"] as? String {
        case "http-429": "Anthropic is rate-limiting the usage check"
        case "http-401", "http-403": "sign-in needs refreshing"
        case .some: "usage check failed"
        case .none: nil
        }
        let retry = self.date(account["usageRetryAt"]).flatMap { at -> String? in
            guard at > now else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "retry \(formatter.string(from: at))"
        }
        return ([age, cause, retry].compactMap(\.self)).joined(separator: "; ") + "."
    }

    static func ageText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return hours < 48 ? "\(hours)h" : "\(hours / 24)d"
    }

    /// Name for a seat, for menu display only.
    ///
    /// `isOrganization` cannot tell the seats apart: a personal Max seat reports true just as a
    /// Team seat does. `organizationName` does differ, but a personal seat's is auto-generated
    /// from the account email, so showing it raw puts an email address in the menu bar. Those are
    /// reported as "Personal" instead, leaving real organisation names to identify work seats.
    static func seatName(_ account: [String: Any]) -> String? {
        guard let raw = account["organizationName"] as? String else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return name.contains("@") ? "Personal" : name
    }

    /// Seat name plus the claude-swap alias, so cards on the same organisation read apart.
    static func displayHint(_ account: [String: Any]) -> String? {
        let parts = [self.seatName(account), self.alias(account)].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A user-set alias such as "work-2". Long values and anything with "@" are dropped, so an
    /// email used as an alias never reaches the menu. Like the seat name, it is display state only.
    static func alias(_ account: [String: Any]) -> String? {
        guard let raw = account["alias"] as? String else { return nil }
        let alias = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, alias.count <= 32, !alias.contains("@"),
              !AgentMeterSnapshotSecurity.containsSensitiveMaterial(Data(alias.utf8)) else { return nil }
        return alias
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func pace(_ raw: [String: Any]) -> AgentMeterFeedPace? {
        let expected = self.nonnegative(raw["expectedPct"]).flatMap { $0 <= 100 ? $0 : nil }
        let ahead = self.boolean(raw["aheadOfPace"])
        let exhaustion = self.date(raw["projectedExhaustionAt"])
        let lasts = self.boolean(raw["willLastToReset"])
        guard expected != nil || ahead != nil || exhaustion != nil || lasts != nil else { return nil }
        return AgentMeterFeedPace(
            expectedPct: expected,
            aheadOfPace: ahead,
            projectedExhaustionAt: exhaustion,
            willLastToReset: lasts)
    }

    private static func nonnegative(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    private static func number(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue > 0, value.doubleValue < Double(Int.max),
              value.doubleValue.rounded() == value.doubleValue else { return nil }
        return value.intValue
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

extension AgentMeterProviderSnapshot {
    public var usageProviderID: String {
        self.providerID ?? self.id
    }

    public var accountDisplayName: String {
        [
            self.displayName,
            self.accountDisplayHint ?? self.accountLabel,
            self.isActiveCLI == true ? "CLI active" : nil,
        ]
            .compactMap(\.self).joined(separator: " · ")
    }

    public var claudeSwapUsageSnapshot: UsageSnapshot {
        func rate(_ window: AgentMeterUsageWindow?) -> RateWindow? {
            guard let window, let used = window.usedPercent else { return nil }
            return RateWindow(
                usedPercent: used,
                windowMinutes: window.windowMinutes,
                resetsAt: window.resetsAt,
                resetDescription: window.resetDescription)
        }
        return UsageSnapshot(
            primary: rate(self.windows.first { $0.id == "session" }),
            secondary: rate(self.windows.first { $0.id == "weekly" }),
            extraRateWindows: self.windows.filter { $0.id != "session" && $0.id != "weekly" }.compactMap { window in
                rate(window).map { NamedRateWindow(id: window.id, title: window.title, window: $0) }
            },
            providerCost: self.spend.flatMap { spend in
                guard let used = spend.used, let limit = spend.limit else { return nil }
                return ProviderCostSnapshot(
                    used: used,
                    limit: limit,
                    currencyCode: spend.currencyCode,
                    period: spend.period,
                    resetsAt: spend.resetsAt,
                    updatedAt: self.updatedAt)
            },
            updatedAt: self.updatedAt)
    }
}

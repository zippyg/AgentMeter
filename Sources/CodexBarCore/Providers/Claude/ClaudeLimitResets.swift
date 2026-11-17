import Foundation

/// Read-only grants. Availability at a usage wall is separate from how many resets are banked.
public struct ClaudeLimitResets: Codable, Sendable, Equatable {
    public struct Grant: Codable, Sendable, Equatable {
        public let label: String
        public let resetsLeft: Int
        public let endsAt: String?
        public let startsAt: String?
        public let clears: [String]
        public let type: String?
        public let givesBackWeekly: Bool?
        public let paused: Bool?
        public let usableNow: Bool?

        enum CodingKeys: String, CodingKey {
            case label, clears, type, paused
            case resetsLeft = "resets_left", endsAt = "ends_at", startsAt = "starts_at"
            case givesBackWeekly = "gives_back_weekly", usableNow = "usable_now"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
            self.resetsLeft = try container.decode(Int.self, forKey: .resetsLeft)
            self.endsAt = try container.decodeIfPresent(String.self, forKey: .endsAt)
            self.startsAt = try container.decodeIfPresent(String.self, forKey: .startsAt)
            self.clears = try container.decodeIfPresent([String].self, forKey: .clears) ?? []
            self.type = try container.decodeIfPresent(String.self, forKey: .type)
            self.givesBackWeekly = try container.decodeIfPresent(Bool.self, forKey: .givesBackWeekly)
            self.paused = try container.decodeIfPresent(Bool.self, forKey: .paused)
            self.usableNow = try container.decodeIfPresent(Bool.self, forKey: .usableNow)
        }

        public var expiresAt: Date? { ClaudeOAuthUsageFetcher.parseISO8601Date(self.endsAt) }
        public var kind: String {
            if [self.label, self.type ?? ""].contains(where: { $0.localizedCaseInsensitiveContains("fable") }) {
                return "Fable reset"
            }
            switch self.type {
            case "session": return "5-hour reset"
            case "weekly": return "Weekly reset"
            case "full": return "Full reset"
            case .some: return Self.safeLabel(self.label) ?? "Unknown reset"
            case nil:
                if self.clears == ["five_hour"] { return "5-hour reset" }
                if !self.clears.isEmpty, self.clears.allSatisfy({ $0 == "seven_day" }) { return "Weekly reset" }
                return Self.safeLabel(self.label) ?? "Unknown reset"
            }
        }
        public func unavailableReason(at now: Date) -> String? {
            if self.paused == true { return "Paused" }
            if self.usableNow == false
                || ClaudeOAuthUsageFetcher.parseISO8601Date(self.startsAt).map({ $0 > now }) == true {
                return "Not yet usable"
            }
            return nil
        }

        private static func safeLabel(_ label: String) -> String? {
            guard !label.isEmpty, label.count <= 80,
                  label.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.whitespaces).union(
                    CharacterSet(charactersIn: "-_.")).contains($0) }) else { return nil }
            return label
        }
    }

    public let grants: [Grant]
    public var fetchedAt: Date? = nil

    enum CodingKeys: String, CodingKey { case grants, eligible, ineligibleReason = "ineligible_reason" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let grants = try container.decode([Grant].self, forKey: .grants)
        let eligible = try container.decodeIfPresent(Bool.self, forKey: .eligible)
        let reason = try container.decodeIfPresent(String.self, forKey: .ineligibleReason)
        guard grants.count <= 64, grants.allSatisfy({ (0...1000).contains($0.resetsLeft) }),
              !grants.isEmpty || eligible == true || reason == "no_grant" else {
            throw DecodingError.dataCorruptedError(forKey: .grants, in: container,
                                                   debugDescription: "Grant listing unavailable or invalid")
        }
        self.grants = grants
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.grants, forKey: .grants)
        try container.encode(true, forKey: .eligible)
    }

    public static func decodeUsage(_ data: Data) throws -> Self? {
        struct Response: Decodable { let cedar_ember: ClaudeLimitResets? }
        return try JSONDecoder().decode(Response.self, from: data).cedar_ember
    }

    public func available(at now: Date) -> [Grant] {
        self.grants.filter { $0.resetsLeft > 0 && ($0.expiresAt == nil || $0.expiresAt! > now) }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    public func count(at now: Date) -> Int {
        self.available(at: now).filter { $0.unavailableReason(at: now) == nil }.reduce(0) { $0 + $1.resetsLeft }
    }

    public func age(at now: Date) -> String? {
        guard let fetchedAt else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(fetchedAt) / 60))
        let age = minutes >= 1440 ? "\(minutes / 1440)d" : minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
        return "as of \(age) ago"
    }
}

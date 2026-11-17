import Foundation

/// Read-only banked resets, separate from purchased usage credits.
public struct CodexResetCredits: Codable, Sendable {
    public let availableCount: Int?
    public let credits: [Credit]?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case credits
    }

    init(availableCount: Int?, credits: [Credit]?) {
        self.availableCount = availableCount
        self.credits = credits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.availableCount = try? container.decodeIfPresent(Int.self, forKey: .availableCount)
        self.credits = (try? container.decodeIfPresent([LossyCredit].self, forKey: .credits))?.compactMap(\.value)
    }

    private struct LossyCredit: Decodable {
        let value: Credit?

        init(from decoder: Decoder) throws {
            self.value = try? Credit(from: decoder)
        }
    }

    public struct Credit: Codable, Sendable {
        public let id: String?
        public let resetType: String?
        public let status: String?
        public let grantedAt: Date?
        public let expiresAt: Date?
        public let title: String?
        public let description: String?

        enum CodingKeys: String, CodingKey {
            case id, status, title, description
            case resetType = "reset_type"
            case grantedAt = "granted_at"
            case expiresAt = "expires_at"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try? container.decodeIfPresent(String.self, forKey: .id)
            self.resetType = try? container.decodeIfPresent(String.self, forKey: .resetType)
            self.status = try? container.decodeIfPresent(String.self, forKey: .status)
            self.title = try? container.decodeIfPresent(String.self, forKey: .title)
            self.description = try? container.decodeIfPresent(String.self, forKey: .description)
            self.grantedAt = Self.date(container, key: .grantedAt)
            self.expiresAt = Self.date(container, key: .expiresAt)
        }

        private static func date(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Date? {
            if let seconds = try? container.decode(Double.self, forKey: key), seconds.isFinite {
                return Date(timeIntervalSince1970: seconds)
            }
            guard let value = try? container.decode(String.self, forKey: key) else { return nil }
            if let seconds = Double(value), seconds.isFinite { return Date(timeIntervalSince1970: seconds) }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(self.resetType, forKey: .resetType)
            try container.encodeIfPresent(self.status, forKey: .status)
            try container.encodeIfPresent(self.title, forKey: .title)
            try container.encodeIfPresent(self.description, forKey: .description)
            try container.encodeIfPresent(self.grantedAt?.timeIntervalSince1970, forKey: .grantedAt)
            try container.encodeIfPresent(self.expiresAt?.timeIntervalSince1970, forKey: .expiresAt)
        }
    }
}

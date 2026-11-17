import Foundation

/// Overflow routing and history deliberately have different lifetimes: history ends only on removal.
public struct CodexOverflowConfiguration: Decodable, Sendable {
    public let home: String
    public let accountEmail: String?
    private let until: String?
    private let enabled: Bool?
    public var switchAt: Double { self.threshold ?? 95 }
    private let threshold: Double?

    private enum CodingKeys: String, CodingKey {
        case home, until, enabled
        case accountEmail = "account_email"
        case threshold = "switch_at"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.home = try values.decode(String.self, forKey: .home)
        self.accountEmail = try? values.decode(String.self, forKey: .accountEmail)
        self.until = try? values.decode(String.self, forKey: .until)
        self.enabled = try? values.decode(Bool.self, forKey: .enabled)
        if values.contains(.threshold) {
            self.threshold = (try? values.decode(Double.self, forKey: .threshold))
                ?? (try? values.decode(String.self, forKey: .threshold)).flatMap(Double.init) ?? .nan
        } else {
            self.threshold = nil
        }
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/codex-overflow.json")
    }

    public static func configurationURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        environment["CODEX_OVERFLOW_CONFIG"].map { URL(fileURLWithPath: $0) } ?? Self.defaultURL
    }

    public static func load(
        from url: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> Self?
    {
        guard let data = try? Data(contentsOf: url ?? Self.configurationURL(environment: environment)),
              let config = try? JSONDecoder().decode(Self.self, from: data),
              !config.home.isEmpty else { return nil }
        return config
    }

    public var homeURL: URL {
        URL(fileURLWithPath: (self.home as NSString).expandingTildeInPath, isDirectory: true)
    }

    public func allowsOverflow(now: Date, calendar: Calendar = .current) -> Bool {
        guard self.enabled != false, let until else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let end = formatter.date(from: until), formatter.string(from: end) == until else { return false }
        return calendar.startOfDay(for: now) <= end
    }
}

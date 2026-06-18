import Foundation

enum AgentMeterPhoneSnapshotStoreError: Error, Equatable {
    case sensitiveMaterialDetected
}

enum AgentMeterPhoneSnapshotSource: Equatable {
    case cache(URL)
    case missing(URL)
    case sample(URL)
}

struct AgentMeterPhoneSnapshotLoadResult: Equatable {
    var snapshot: AgentMeterPhoneSnapshot
    var source: AgentMeterPhoneSnapshotSource
}

enum AgentMeterPhoneSnapshotStore {
    static let filename = "agentmeter-phone-snapshot.json"
    static let appGroupIdentifierInfoKey = "AgentMeterAppGroupIdentifier"

    static func load(fileURL: URL = Self.defaultURL()) throws -> AgentMeterPhoneSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try self.decoder.decode(AgentMeterPhoneSnapshot.self, from: data).primaryProjection()
    }

    static func loadOrSample(fileURL: URL = Self.defaultURL(), now: Date = Date()) -> AgentMeterPhoneSnapshotLoadResult {
        if let snapshot = try? self.load(fileURL: fileURL) {
            return AgentMeterPhoneSnapshotLoadResult(snapshot: snapshot, source: .cache(fileURL))
        }
        return AgentMeterPhoneSnapshotLoadResult(
            snapshot: AgentMeterSampleData.emptySnapshot(now: now),
            source: .missing(fileURL))
    }

    static func save(_ snapshot: AgentMeterPhoneSnapshot, fileURL: URL = Self.defaultURL()) throws {
        let projected = snapshot.primaryProjection()
        let data = try self.encoder.encode(projected)
        guard !self.containsSensitiveMaterial(data) else {
            throw AgentMeterPhoneSnapshotStoreError.sensitiveMaterialDetected
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
        try self.applyFileProtection(fileURL)
    }

    static func importSnapshot(from sourceURL: URL, fileURL: URL = Self.defaultURL()) throws -> AgentMeterPhoneSnapshot {
        let data = try Data(contentsOf: sourceURL)
        return try self.importSnapshotData(data, fileURL: fileURL)
    }

    static func importSnapshotData(_ data: Data, fileURL: URL = Self.defaultURL()) throws -> AgentMeterPhoneSnapshot {
        guard !self.containsSensitiveMaterial(data) else {
            throw AgentMeterPhoneSnapshotStoreError.sensitiveMaterialDetected
        }
        let snapshot = try self.decoder.decode(AgentMeterPhoneSnapshot.self, from: data)
        try self.save(snapshot, fileURL: fileURL)
        return try self.load(fileURL: fileURL) ?? snapshot.primaryProjection()
    }

    static func defaultURL(
        fileManager: FileManager = .default,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> URL {
        self.defaultURL(
            fileManager: fileManager,
            appGroupIdentifier: self.configuredAppGroupIdentifier(infoDictionary: infoDictionary))
    }

    static func defaultURL(fileManager: FileManager = .default, appGroupIdentifier: String?) -> URL {
        if let appGroupIdentifier = self.normalizedAppGroupIdentifier(appGroupIdentifier),
           let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return groupURL.appendingPathComponent(self.filename, isDirectory: false)
        }
        return self.fallbackURL(fileManager: fileManager)
    }

    static func fallbackURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("AgentMeter", isDirectory: true)
            .appendingPathComponent(self.filename, isDirectory: false)
    }

    static func configuredAppGroupIdentifier(infoDictionary: [String: Any]) -> String? {
        self.normalizedAppGroupIdentifier(infoDictionary[self.appGroupIdentifierInfoKey] as? String)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func containsSensitiveMaterial(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        let markers = [
            "apikey",
            "api_key",
            "bearer ",
            "cookie",
            "refresh_token",
            "access_token",
            "client_secret",
            "password",
            "sk-",
            "ghp_",
        ]
        return markers.contains { text.contains($0) }
    }

    private static func normalizedAppGroupIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("group."), trimmed.count > "group.".count else { return nil }
        return trimmed
    }

    private static func applyFileProtection(_ fileURL: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path)
        #endif
    }
}

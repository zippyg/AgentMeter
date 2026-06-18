import Foundation
#if os(macOS)
import Security
#endif

public enum AppGroupSupport {
    public static let defaultTeamID = "AGENTMETER"
    public static let teamIDInfoKey = "AgentMeterTeamID"
    public static let legacyTeamIDInfoKey = "CodexBarTeamID"
    public static let appGroupIdentifierInfoKey = "AgentMeterAppGroupIdentifier"
    public static let releaseGroupID = AgentMeterIdentity.releaseAppGroupID
    public static let debugGroupID = AgentMeterIdentity.debugAppGroupID
    public static let legacyReleaseGroupID = "group.com.steipete.codexbar"
    public static let legacyDebugGroupID = "group.com.steipete.codexbar.debug"
    public static let widgetSnapshotFilename = "widget-snapshot.json"
    public static let migrationVersion = 1
    public static let migrationVersionKey = "appGroupMigrationVersion"
    private static let sharedDefaultsMigrationKeys = [
        "debugDisableKeychainAccess",
        "widgetSelectedProvider",
    ]

    public struct MigrationResult: Sendable {
        public enum Status: String, Sendable {
            case alreadyCompleted
            case targetUnavailable
            case noChangesNeeded
            case migrated
        }

        public let status: Status
        public let copiedSnapshot: Bool
        public let copiedDefaults: Int

        public init(status: Status, copiedSnapshot: Bool = false, copiedDefaults: Int = 0) {
            self.status = status
            self.copiedSnapshot = copiedSnapshot
            self.copiedDefaults = copiedDefaults
        }
    }

    public static func currentGroupID(for bundleID: String? = Bundle.main.bundleIdentifier) -> String {
        self.currentGroupID(
            configuredGroupID: self.configuredAppGroupID(),
            bundleID: bundleID)
    }

    static func currentGroupID(teamID _: String, bundleID: String?) -> String {
        self.currentGroupID(configuredGroupID: nil, bundleID: bundleID)
    }

    static func currentGroupID(configuredGroupID: String?, bundleID: String?) -> String {
        if let configuredGroupID = self.normalizedAppGroupID(configuredGroupID) {
            return configuredGroupID
        }
        return self.isDebugBundleID(bundleID) ? self.debugGroupID : self.releaseGroupID
    }

    public static func resolvedTeamID(bundle: Bundle = .main) -> String {
        self.resolvedTeamID(
            infoDictionaryOverride: bundle.infoDictionary,
            bundleURLOverride: bundle.bundleURL)
    }

    static func resolvedTeamID(
        infoDictionaryOverride: [String: Any]?,
        bundleURLOverride: URL?) -> String
    {
        if let teamID = self.codeSignatureTeamID(bundleURL: bundleURLOverride) {
            return teamID
        }
        if let teamID = infoDictionaryOverride?[self.teamIDInfoKey] as? String,
           !teamID.isEmpty
        {
            return teamID
        }
        if let teamID = infoDictionaryOverride?[self.legacyTeamIDInfoKey] as? String,
           !teamID.isEmpty
        {
            return teamID
        }
        return self.defaultTeamID
    }

    public static func configuredAppGroupID(bundle: Bundle = .main) -> String? {
        self.configuredAppGroupID(infoDictionaryOverride: bundle.infoDictionary)
    }

    static func configuredAppGroupID(infoDictionaryOverride: [String: Any]?) -> String? {
        self.normalizedAppGroupID(infoDictionaryOverride?[self.appGroupIdentifierInfoKey] as? String)
    }

    public static func legacyGroupID(for bundleID: String? = Bundle.main.bundleIdentifier) -> String {
        self.isDebugBundleID(bundleID) ? self.legacyDebugGroupID : self.legacyReleaseGroupID
    }

    public static func sharedDefaults(
        bundleID: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default)
        -> UserDefaults?
    {
        guard self.currentContainerURL(bundleID: bundleID, fileManager: fileManager) != nil else { return nil }
        return UserDefaults(suiteName: self.currentGroupID(for: bundleID))
    }

    public static func currentContainerURL(
        bundleID: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default)
        -> URL?
    {
        #if os(macOS)
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: self.currentGroupID(for: bundleID))
        #else
        nil
        #endif
    }

    public static func snapshotURL(
        bundleID: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> URL
    {
        if let container = self.currentContainerURL(bundleID: bundleID, fileManager: fileManager) {
            return container.appendingPathComponent(self.widgetSnapshotFilename, isDirectory: false)
        }

        let directory = self.localFallbackDirectory(fileManager: fileManager, homeDirectory: homeDirectory)
        return directory.appendingPathComponent(self.widgetSnapshotFilename, isDirectory: false)
    }

    public static func localFallbackDirectory(
        fileManager: FileManager = .default,
        homeDirectory _: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> URL
    {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("AgentMeter", isDirectory: true)
        try? AgentMeterFileSecurity.ensurePrivateDirectory(directory, fileManager: fileManager)
        return directory
    }

    public static func legacyContainerCandidateURL(
        bundleID: String? = Bundle.main.bundleIdentifier,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> URL
    {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(self.legacyGroupID(for: bundleID), isDirectory: true)
    }

    public static func migrateLegacyDataIfNeeded(
        bundleID: String? = Bundle.main.bundleIdentifier,
        standardDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        currentDefaultsOverride: UserDefaults? = nil,
        legacyDefaultsOverride: UserDefaults? = nil,
        currentSnapshotURLOverride: URL? = nil,
        legacySnapshotURLOverride: URL? = nil)
        -> MigrationResult
    {
        if standardDefaults.integer(forKey: self.migrationVersionKey) >= self.migrationVersion {
            return MigrationResult(status: .alreadyCompleted)
        }

        guard let currentDefaults = currentDefaultsOverride ?? self.sharedDefaults(
            bundleID: bundleID,
            fileManager: fileManager)
        else {
            return MigrationResult(status: .targetUnavailable)
        }

        let legacyDefaults = legacyDefaultsOverride ?? UserDefaults(suiteName: self.legacyGroupID(for: bundleID))
        let currentSnapshotURL = currentSnapshotURLOverride
            ?? self.currentContainerURL(bundleID: bundleID, fileManager: fileManager)?
            .appendingPathComponent(self.widgetSnapshotFilename, isDirectory: false)
        let legacySnapshotURL = legacySnapshotURLOverride
            ?? self.legacyContainerCandidateURL(bundleID: bundleID, homeDirectory: homeDirectory)
            .appendingPathComponent(self.widgetSnapshotFilename, isDirectory: false)

        let copiedSnapshot = {
            guard let currentSnapshotURL else { return false }
            guard !fileManager.fileExists(atPath: currentSnapshotURL.path),
                  fileManager.fileExists(atPath: legacySnapshotURL.path)
            else {
                return false
            }
            do {
                try fileManager.createDirectory(
                    at: currentSnapshotURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try fileManager.copyItem(at: legacySnapshotURL, to: currentSnapshotURL)
                return true
            } catch {
                return false
            }
        }()

        let copiedDefaults = self.copyLegacySharedDefaults(
            from: legacyDefaults,
            to: currentDefaults)

        let result = if copiedSnapshot || copiedDefaults > 0 {
            MigrationResult(
                status: .migrated,
                copiedSnapshot: copiedSnapshot,
                copiedDefaults: copiedDefaults)
        } else {
            MigrationResult(status: .noChangesNeeded)
        }

        standardDefaults.set(self.migrationVersion, forKey: self.migrationVersionKey)
        return result
    }

    private static func copyLegacySharedDefaults(
        from legacyDefaults: UserDefaults?,
        to currentDefaults: UserDefaults) -> Int
    {
        guard let legacyDefaults else { return 0 }

        var copied = 0
        for key in self.sharedDefaultsMigrationKeys {
            guard currentDefaults.object(forKey: key) == nil,
                  let legacyValue = legacyDefaults.object(forKey: key)
            else {
                continue
            }
            currentDefaults.set(legacyValue, forKey: key)
            copied += 1
        }
        return copied
    }

    private static func isDebugBundleID(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return bundleID.contains(".debug")
    }

    private static func normalizedAppGroupID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("group."), trimmed.count > "group.".count else { return nil }
        return trimmed
    }

    private static func codeSignatureTeamID(bundleURL: URL?) -> String? {
        #if os(macOS)
        guard let bundleURL else { return nil }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode
        else {
            return nil
        }

        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF) == errSecSuccess,
            let info = infoCF as? [String: Any],
            let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String,
            !teamID.isEmpty
        else {
            return nil
        }
        return teamID
        #else
        _ = bundleURL
        return nil
        #endif
    }
}

import Foundation

enum MenuBarStatusItemDefaultsRepair {
    private static let preferredPositionPrefix = "NSStatusItem Preferred Position "
    private static let visibilityPrefixes = [
        "NSStatusItem Visible ",
        "NSStatusItem VisibleCC ",
    ]
    private static let statusItemPreferencePrefixes = [
        preferredPositionPrefix,
        "NSStatusItem Visible ",
        "NSStatusItem VisibleCC ",
    ]
    private static let managedAutosavePrefixes = [
        "\(AgentMeterProductIdentity.legacyStatusItemAutosavePrefix)-",
        "\(AgentMeterProductIdentity.previousLocalStatusItemAutosaveRoot).",
        "\(AgentMeterProductIdentity.previousMacBundleIdentifier).",
        "\(AgentMeterProductIdentity.bundleIdentifier).",
    ] + AgentMeterProductIdentity.previousVersionedStatusItemAutosaveRoots.map { "\($0)-" }

    static func repairHiddenVisibilityDefaultsIfNeeded(defaults: UserDefaults) -> [String] {
        let repairedKeys = defaults.dictionaryRepresentation().keys
            .filter { key in
                self.shouldRepair(
                    key: key,
                    value: defaults.object(forKey: key))
            }
            .sorted()

        for key in repairedKeys {
            defaults.removeObject(forKey: key)
        }
        return repairedKeys
    }

    @discardableResult
    static func migrateLegacyStatusItemDefaults(
        defaults: UserDefaults,
        autosaveName: String,
        legacyAutosaveNames: [String])
        -> [String]
    {
        guard !legacyAutosaveNames.isEmpty else { return [] }

        var changedKeys: [String] = []
        for prefix in self.statusItemPreferencePrefixes {
            let newKey = "\(prefix)\(autosaveName)"
            let shouldCopyLegacyValue = prefix != self.preferredPositionPrefix
            for legacyAutosaveName in legacyAutosaveNames {
                let legacyKey = "\(prefix)\(legacyAutosaveName)"
                guard let legacyValue = defaults.object(forKey: legacyKey) else { continue }
                if shouldCopyLegacyValue,
                   !self.isFalse(legacyValue),
                   defaults.object(forKey: newKey) == nil
                {
                    defaults.set(legacyValue, forKey: newKey)
                    changedKeys.append(newKey)
                }
                defaults.removeObject(forKey: legacyKey)
                changedKeys.append(legacyKey)
            }
        }

        if !changedKeys.isEmpty {
            defaults.synchronize()
        }
        return changedKeys.sorted()
    }

    static func shouldRepair(
        key: String,
        value: Any?)
        -> Bool
    {
        guard let visibilityPrefix = self.visibilityPrefixes.first(where: { key.hasPrefix($0) }),
              self.isFalse(value)
        else { return false }
        let itemName = String(key.dropFirst(visibilityPrefix.count))
        return self.isLegacyStatusItemName(itemName)
    }

    private static func isLegacyStatusItemName(_ itemName: String) -> Bool {
        self.managedAutosavePrefixes.contains { itemName.hasPrefix($0) }
            || itemName == AgentMeterProductIdentity.bundleIdentifier
            || itemName == AgentMeterProductIdentity.previousMacBundleIdentifier
            || itemName == AgentMeterProductIdentity.previousLocalStatusItemAutosaveRoot
    }

    private static func isFalse(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber:
            !number.boolValue
        case let bool as Bool:
            !bool
        default:
            false
        }
    }
}

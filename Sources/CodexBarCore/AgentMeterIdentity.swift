import Foundation

/// Single source of truth for AgentMeter's reverse-DNS identity prefix.
///
/// To rebrand a fork, change `bundlePrefix` here and the matching build-config
/// identifiers that a Swift constant cannot reach (see FORKING.md): the macOS
/// bundle id in `AgentMeterProductIdentity` and Info.plist, and the iOS targets'
/// bundle ids / App Group / Keychain access group in `AgentMeteriOS`.
///
/// The derived values below must resolve to the exact strings AgentMeter already
/// ships, or stored Keychain items, App Group containers, and the cross-process
/// snapshot notification would be orphaned. `AgentMeterIdentityTests` pins each one.
public enum AgentMeterIdentity {
    public static let bundlePrefix = "com.zain.agentmeter"

    public static let keychainService = bundlePrefix
    public static let cacheService = bundlePrefix + ".cache"
    public static let releaseAppGroupID = "group." + bundlePrefix
    public static let debugAppGroupID = "group." + bundlePrefix + ".debug"
    public static let snapshotUpdatedNotification = bundlePrefix + ".snapshot.updated"
    public static let logSubsystem = bundlePrefix
}

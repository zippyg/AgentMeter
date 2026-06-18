import Foundation

enum AgentMeterProductIdentity {
    static let displayName = "AgentMeter"
    static let upstreamName = "CodexBar"
    static let bundleIdentifier = "com.zain.agentmeter.menu"
    static let previousMacBundleIdentifier = "com.zain.agentmeter.mac"
    static let previousLocalStatusItemAutosaveRoot = "com.zain.agentmeter.local"
    static let previousVersionedStatusItemAutosaveRoots = [
        "com.zain.agentmeter.statusitem.v2",
        "com.zain.agentmeter.statusitem.v3",
        "com.zain.agentmeter.statusitem.v5",
        "agentmeter-v4",
    ]
    static let legacyStatusItemAutosavePrefix = "agentmeter"
    static let statusItemAutosaveRoot = bundleIdentifier
    static let statusItemAccessibilityIdentifierPrefix = "AgentMeter.StatusItem"

    static func bundleMetadata(agentMeterKey: String, upstreamKey: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: agentMeterKey) as? String
            ?? Bundle.main.object(forInfoDictionaryKey: upstreamKey) as? String
    }
}

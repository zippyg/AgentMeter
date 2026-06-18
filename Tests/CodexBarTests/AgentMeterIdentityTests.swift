import Testing
@testable import CodexBarCore

/// Pins every identity string derived from `AgentMeterIdentity.bundlePrefix` to the
/// exact literal AgentMeter already ships. If a refactor changes any resolved value,
/// these fail before the change can orphan Keychain items, the App Group container,
/// or the cross-process snapshot notification.
struct AgentMeterIdentityTests {
    @Test
    func `prefix and derived identity strings are unchanged`() {
        #expect(AgentMeterIdentity.bundlePrefix == "com.zain.agentmeter")
        #expect(AgentMeterIdentity.keychainService == "com.zain.agentmeter")
        #expect(AgentMeterIdentity.cacheService == "com.zain.agentmeter.cache")
        #expect(AgentMeterIdentity.releaseAppGroupID == "group.com.zain.agentmeter")
        #expect(AgentMeterIdentity.debugAppGroupID == "group.com.zain.agentmeter.debug")
        #expect(AgentMeterIdentity.snapshotUpdatedNotification == "com.zain.agentmeter.snapshot.updated")
        #expect(AgentMeterIdentity.logSubsystem == "com.zain.agentmeter")
    }

    @Test
    func `consumers resolve to the shipped identity values`() {
        #expect(AgentMeterKeychainCredentialStore.serviceName == "com.zain.agentmeter")
        #expect(KeychainCacheStore.defaultCacheService == "com.zain.agentmeter.cache")
        #expect(AppGroupSupport.releaseGroupID == "group.com.zain.agentmeter")
        #expect(AppGroupSupport.debugGroupID == "group.com.zain.agentmeter.debug")
        #expect(AgentMeterSnapshotNotification.name == "com.zain.agentmeter.snapshot.updated")
    }
}

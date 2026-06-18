import Darwin
import Foundation
import Testing
@testable import AgentMeter

struct AgentMeterBridgeRuntimeStoreTests {
    @Test
    func `save records the active bridge owner`() throws {
        let defaults = try self.makeDefaults("save-records-owner")

        AgentMeterBridgeRuntimeStore.save(port: 54042, processID: 1234, defaults: defaults)

        #expect(AgentMeterBridgeRuntimeStore.currentPort(defaults: defaults) == 54042)
        #expect(AgentMeterBridgeRuntimeStore.activePort(
            defaults: defaults,
            processIsRunning: { $0 == 1234 },
            legacyHealthProbe: { $0 == 54042 }) == 54042)
    }

    @Test
    func `owned clear does not remove another process port`() throws {
        let defaults = try self.makeDefaults("clear-preserves-other-owner")
        AgentMeterBridgeRuntimeStore.save(port: 54042, processID: 1234, defaults: defaults)

        AgentMeterBridgeRuntimeStore.clearOwned(port: 54042, processID: 5678, defaults: defaults)

        #expect(AgentMeterBridgeRuntimeStore.currentPort(defaults: defaults) == 54042)
    }

    @Test
    func `owned clear removes the matching process port`() throws {
        let defaults = try self.makeDefaults("clear-removes-matching-owner")
        AgentMeterBridgeRuntimeStore.save(port: 54042, processID: 1234, defaults: defaults)

        AgentMeterBridgeRuntimeStore.clearOwned(port: 54042, processID: 1234, defaults: defaults)

        #expect(AgentMeterBridgeRuntimeStore.currentPort(defaults: defaults) == nil)
    }

    @Test
    func `active port rejects dead owned process`() throws {
        let defaults = try self.makeDefaults("active-rejects-dead-owner")
        AgentMeterBridgeRuntimeStore.save(port: 54042, processID: 1234, defaults: defaults)

        let port = AgentMeterBridgeRuntimeStore.activePort(
            defaults: defaults,
            processIsRunning: { _ in false },
            legacyHealthProbe: { _ in true })

        #expect(port == nil)
    }

    @Test
    func `active port rejects running owner with failed health probe`() throws {
        let defaults = try self.makeDefaults("active-rejects-running-owner-failed-health")
        AgentMeterBridgeRuntimeStore.save(port: 54042, processID: 1234, defaults: defaults)

        let port = AgentMeterBridgeRuntimeStore.activePort(
            defaults: defaults,
            processIsRunning: { $0 == 1234 },
            legacyHealthProbe: { _ in false })

        #expect(port == nil)
    }

    @Test
    func `active port validates legacy values by health probe`() throws {
        let defaults = try self.makeDefaults("active-validates-legacy")
        defaults.set(54042, forKey: "agentMeterBridgePort")

        let activePort = AgentMeterBridgeRuntimeStore.activePort(
            defaults: defaults,
            processIsRunning: { _ in false },
            legacyHealthProbe: { $0 == 54042 })

        #expect(activePort == 54042)

        let deadPort = AgentMeterBridgeRuntimeStore.activePort(
            defaults: defaults,
            processIsRunning: { _ in false },
            legacyHealthProbe: { _ in false })

        #expect(deadPort == nil)
    }

    private func makeDefaults(_ name: String) throws -> UserDefaults {
        let suiteName = "AgentMeterBridgeRuntimeStoreTests-\(name)-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

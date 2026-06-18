import CodexBarCore
import Foundation
import Testing

struct AgentMeterBridgeTokenStoreTests {
    @Test
    func `new pairing secret is scoped to a device id`() throws {
        let suite = "AgentMeterBridgeTokenStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryAgentMeterCredentialStore()

        let secret = try #require(AgentMeterBridgeTokenStore.createPairingSecret(
            defaults: defaults,
            store: store))

        #expect(secret.deviceID.count >= 16)
        #expect(secret.token.count >= 32)
        #expect(secret.token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(AgentMeterBridgeTokenStore.tokenForRequest(
            deviceID: secret.deviceID,
            defaults: defaults,
            store: store) == secret.token)
    }

    @Test
    func `unknown device id is rejected instead of falling back to legacy token`() throws {
        let suite = "AgentMeterBridgeTokenStoreTests-unknown-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryAgentMeterCredentialStore()

        #expect(AgentMeterBridgeTokenStore.loadOrCreate(store: store) != nil)
        #expect(AgentMeterBridgeTokenStore.tokenForRequest(
            deviceID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            defaults: defaults,
            store: store) == nil)
        #expect(AgentMeterBridgeTokenStore.tokenForRequest(
            deviceID: nil,
            defaults: defaults,
            store: store) != nil)
    }

    @Test
    func `pairing url includes per device id when provided`() throws {
        let url = try #require(AgentMeterBridgeTokenStore.pairingURL(
            serviceName: "AgentMeter Test Mac",
            token: String(repeating: "a", count: 48),
            deviceID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            directHost: "192.0.2.10",
            directPort: 49200))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        #expect(url.scheme == "agentmeter")
        #expect(url.host == "pair")
        #expect(value("service") == "AgentMeter Test Mac")
        #expect(value("type") == AgentMeterBridgeTokenStore.serviceType)
        #expect(value("token") == String(repeating: "a", count: 48))
        #expect(value(AgentMeterBridgeTokenStore.deviceQueryItemName) == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(value("host") == "192.0.2.10")
        #expect(value("port") == "49200")
    }
}

private final class InMemoryAgentMeterCredentialStore: AgentMeterCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AgentMeterCredentialReference: String] = [:]

    func store(_ secret: String, for reference: AgentMeterCredentialReference) throws {
        self.lock.lock()
        self.values[reference] = secret
        self.lock.unlock()
    }

    func load(reference: AgentMeterCredentialReference) throws -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values[reference]
    }

    func delete(reference: AgentMeterCredentialReference) throws {
        self.lock.lock()
        self.values.removeValue(forKey: reference)
        self.lock.unlock()
    }
}

import CodexBarCore
import CryptoKit
import Foundation
import Testing
@testable import AgentMeter

struct AgentMeterBridgePairingCoordinatorTests {
    @Test
    func `secure pairing invitation does not expose token or code`() throws {
        let coordinator = AgentMeterBridgePairingCoordinator()
        let invitation = try #require(coordinator.createInvitation(
            serviceName: "AgentMeter Test Mac",
            directHost: "192.0.2.10",
            directPort: 49200))
        let items = URLComponents(url: invitation.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        #expect(invitation.url.scheme == "agentmeter")
        #expect(invitation.url.host == "pair")
        #expect(value("v") == "2")
        #expect(value("service") == "AgentMeter Test Mac")
        #expect(value("session") == invitation.sessionID)
        #expect(value("macKey") == invitation.publicKey)
        #expect(value("host") == "192.0.2.10")
        #expect(value("port") == "49200")
        #expect(value("token") == nil)
        #expect(value("code") == nil)
        #expect(invitation.code.count == 12)
        #expect(invitation.code.allSatisfy { Self.pairingCodeAlphabet.contains($0) })
        #expect(invitation.displayCode.split(separator: " ").map(\.count) == [4, 4, 4])
        #expect(!invitation.url.absoluteString.contains(invitation.code))
    }

    @Test
    func `secure pairing completes with encrypted per device token`() throws {
        let suite = "AgentMeterBridgePairingCoordinatorTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryPairingCredentialStore()
        let coordinator = AgentMeterBridgePairingCoordinator()
        let invitation = try #require(coordinator.createInvitation(
            serviceName: "AgentMeter Test Mac",
            directHost: "127.0.0.1",
            directPort: 54042))
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let clientPublicKey = privateKey.publicKey.rawRepresentation.agentMeterBase64URLEncodedString()
        let macPublicKeyData = try #require(Data(agentMeterBase64URL: invitation.publicKey))
        let macPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: macPublicKeyData)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: macPublicKey)
        let context = AgentMeterBridgePairingCrypto.context(
            sessionID: invitation.sessionID,
            macPublicKey: invitation.publicKey,
            clientPublicKey: clientPublicKey)
        let proofKey = AgentMeterBridgePairingCrypto.derivedKey(
            from: sharedSecret,
            purpose: "proof",
            context: context)
        let proof = AgentMeterBridgePairingCrypto.proof(code: invitation.code, key: proofKey, context: context)

        let result = coordinator.complete(
            sessionID: invitation.sessionID,
            clientPublicKey: clientPublicKey,
            proof: proof,
            defaults: defaults,
            store: store)
        let responseData: Data
        switch result {
        case let .success(data):
            responseData = data
        case let .failure(error):
            Issue.record("Pairing failed with \(error)")
            return
        }

        let response = try JSONDecoder().decode(PairingResponse.self, from: responseData)
        let payloadKey = AgentMeterBridgePairingCrypto.derivedKey(
            from: sharedSecret,
            purpose: "payload",
            context: context)
        let sealedData = try #require(Data(agentMeterBase64URL: response.encryptedPayload))
        let payloadData = try ChaChaPoly.open(
            ChaChaPoly.SealedBox(combined: sealedData),
            using: payloadKey,
            authenticating: context)
        let payload = try JSONDecoder().decode(PairingPayload.self, from: payloadData)

        #expect(response.schemaVersion == 1)
        #expect(payload.schemaVersion == 1)
        #expect(response.deviceID == payload.deviceID)
        #expect(payload.serviceName == "AgentMeter Test Mac")
        #expect(payload.serviceType == AgentMeterBridgeTokenStore.serviceType)
        #expect(payload.directHost == "127.0.0.1")
        #expect(payload.directPort == 54042)
        #expect(payload.token.count >= 32)
        #expect(AgentMeterBridgeTokenStore.tokenForRequest(
            deviceID: payload.deviceID,
            defaults: defaults,
            store: store) == payload.token)
    }

    @Test
    func `bad pairing proof does not create paired device`() throws {
        let suite = "AgentMeterBridgePairingCoordinatorTests-bad-proof-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryPairingCredentialStore()
        let coordinator = AgentMeterBridgePairingCoordinator()
        let invitation = try #require(coordinator.createInvitation(
            serviceName: "AgentMeter Test Mac",
            directHost: nil,
            directPort: nil))
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let clientPublicKey = privateKey.publicKey.rawRepresentation.agentMeterBase64URLEncodedString()

        let result = coordinator.complete(
            sessionID: invitation.sessionID,
            clientPublicKey: clientPublicKey,
            proof: "not-a-valid-proof",
            defaults: defaults,
            store: store)

        #expect(result == .failure(.badProof))
        #expect(AgentMeterBridgeTokenStore.tokenForRequest(
            deviceID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            defaults: defaults,
            store: store) == nil)
    }
}

extension AgentMeterBridgePairingCoordinatorTests {
    private static let pairingCodeAlphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
}

private struct PairingResponse: Decodable {
    let schemaVersion: Int
    let deviceID: String
    let encryptedPayload: String
}

private struct PairingPayload: Decodable {
    let schemaVersion: Int
    let serviceName: String
    let serviceType: String
    let token: String
    let deviceID: String
    let directHost: String?
    let directPort: UInt16?
}

private final class InMemoryPairingCredentialStore: AgentMeterCredentialStoring, @unchecked Sendable {
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

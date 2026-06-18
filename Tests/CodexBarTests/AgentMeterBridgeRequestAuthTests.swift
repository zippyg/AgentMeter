import Foundation
import Testing
@testable import AgentMeter

struct AgentMeterBridgeRequestAuthTests {
    @Test
    func `authorizes signed bridge request without transmitting token`() {
        let token = String(repeating: "a", count: 48)
        let timestamp = "1780000000"
        let nonce = String(repeating: "n", count: 32)
        let alternateNonce = String(repeating: "m", count: 32)
        let signature = AgentMeterBridgeRequestAuth.signature(
            method: "GET",
            path: "/snapshot",
            timestamp: timestamp,
            nonce: nonce,
            token: token)
        let authorizer = AgentMeterBridgeRequestAuthorizer()

        #expect(authorizer.isAuthorized(
            method: "GET",
            path: "/snapshot",
            headers: [
                AgentMeterBridgeRequestAuth.timestampHeader: timestamp,
                AgentMeterBridgeRequestAuth.nonceHeader: nonce,
                AgentMeterBridgeRequestAuth.signatureHeader: signature,
            ],
            token: token,
            now: Date(timeIntervalSince1970: 1_780_000_100)))
        #expect(authorizer.authorizationResult(
            method: "GET",
            path: "/snapshot",
            headers: [
                AgentMeterBridgeRequestAuth.timestampHeader: timestamp,
                AgentMeterBridgeRequestAuth.nonceHeader: alternateNonce,
                AgentMeterBridgeRequestAuth.signatureHeader: AgentMeterBridgeRequestAuth.signature(
                    method: "GET",
                    path: "/snapshot",
                    timestamp: timestamp,
                    nonce: alternateNonce,
                    token: token),
            ],
            token: token,
            now: Date(timeIntervalSince1970: 1_780_000_100)) == .allowed)
    }

    @Test
    func `rejects replayed bridge nonce`() {
        let token = String(repeating: "b", count: 48)
        let timestamp = "1780000000"
        let nonce = "nonce_1234567890_REPLAY_nonce"
        let signature = AgentMeterBridgeRequestAuth.signature(
            method: "GET",
            path: "/snapshot",
            timestamp: timestamp,
            nonce: nonce,
            token: token)
        let headers = [
            AgentMeterBridgeRequestAuth.timestampHeader: timestamp,
            AgentMeterBridgeRequestAuth.nonceHeader: nonce,
            AgentMeterBridgeRequestAuth.signatureHeader: signature,
        ]
        let authorizer = AgentMeterBridgeRequestAuthorizer()
        let now = Date(timeIntervalSince1970: 1_780_000_100)

        #expect(authorizer.isAuthorized(method: "GET", path: "/snapshot", headers: headers, token: token, now: now))
        #expect(!authorizer.isAuthorized(method: "GET", path: "/snapshot", headers: headers, token: token, now: now))
    }

    @Test
    func `rejects stale bridge timestamp`() {
        let token = String(repeating: "c", count: 48)
        let timestamp = "1780000000"
        let nonce = "nonce_1234567890_STALE_nonce"
        let signature = AgentMeterBridgeRequestAuth.signature(
            method: "GET",
            path: "/snapshot",
            timestamp: timestamp,
            nonce: nonce,
            token: token)

        #expect(!AgentMeterBridgeRequestAuthorizer().isAuthorized(
            method: "GET",
            path: "/snapshot",
            headers: [
                AgentMeterBridgeRequestAuth.timestampHeader: timestamp,
                AgentMeterBridgeRequestAuth.nonceHeader: nonce,
                AgentMeterBridgeRequestAuth.signatureHeader: signature,
            ],
            token: token,
            now: Date(timeIntervalSince1970: 1_780_001_000)))
        #expect(AgentMeterBridgeRequestAuthorizer().authorizationResult(
            method: "GET",
            path: "/snapshot",
            headers: [
                AgentMeterBridgeRequestAuth.timestampHeader: timestamp,
                AgentMeterBridgeRequestAuth.nonceHeader: nonce,
                AgentMeterBridgeRequestAuth.signatureHeader: signature,
            ],
            token: token,
            now: Date(timeIntervalSince1970: 1_780_001_000)) == .denied(.clockSkew))
    }

    @Test
    func `rejects legacy raw token bridge header`() {
        #expect(!AgentMeterBridgeRequestAuthorizer().isAuthorized(
            method: "GET",
            path: "/snapshot",
            headers: ["x-agentmeter-bridge-token": String(repeating: "d", count: 48)],
            token: String(repeating: "d", count: 48),
            now: Date(timeIntervalSince1970: 1_780_000_000)))
    }

    @Test
    func `reports bad signature reason`() {
        let nonce = String(repeating: "s", count: 32)
        let result = AgentMeterBridgeRequestAuthorizer().authorizationResult(
            method: "GET",
            path: "/snapshot",
            headers: [
                AgentMeterBridgeRequestAuth.timestampHeader: "1780000000",
                AgentMeterBridgeRequestAuth.nonceHeader: nonce,
                AgentMeterBridgeRequestAuth.signatureHeader: "not-the-right-signature",
            ],
            token: String(repeating: "e", count: 48),
            now: Date(timeIntervalSince1970: 1_780_000_100))

        #expect(result == .denied(.badSignature))
    }
}

import CodexBarCore
import CryptoKit
import Foundation
import Security

struct AgentMeterBridgePairingInvitation: Equatable, Sendable {
    let serviceName: String
    let serviceType: String
    let sessionID: String
    let publicKey: String
    let code: String
    let directHost: String?
    let directPort: UInt16?
    let url: URL

    var displayCode: String {
        self.code
            .enumerated()
            .map { index, character in
                index > 0 && index.isMultiple(of: 4) ? " \(character)" : String(character)
            }
            .joined()
    }
}

enum AgentMeterBridgePairingError: Error, Equatable {
    case invalidRequest
    case sessionNotFound
    case sessionExpired
    case tooManyAttempts
    case badProof
    case keychainUnavailable
    case encryptionFailed
}

final class AgentMeterBridgePairingCoordinator: @unchecked Sendable {
    static let shared = AgentMeterBridgePairingCoordinator()

    private struct PendingSession {
        let serviceName: String
        let serviceType: String
        let sessionID: String
        let code: String
        let agreementKey: Curve25519.KeyAgreement // gitleaks:allow
            .PrivateKey
        let publicKey: String
        let directHost: String?
        let directPort: UInt16?
        let createdAt: Date
        var attempts: Int
    }

    private struct PairingResponse: Codable {
        let schemaVersion: Int
        let sessionID: String
        let deviceID: String
        let encryptedPayload: String
    }

    private struct PairingPayload: Codable {
        let schemaVersion: Int
        let serviceName: String
        let serviceType: String
        let token: String
        let deviceID: String
        let directHost: String?
        let directPort: UInt16?
    }

    private let lock = NSLock()
    private var sessions: [String: PendingSession] = [:]
    private let sessionTTL: TimeInterval
    private let maxAttempts: Int

    private static let pairingCodeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let pairingCodeLength = 12

    init(sessionTTL: TimeInterval = 10 * 60, maxAttempts: Int = 5) {
        self.sessionTTL = sessionTTL
        self.maxAttempts = maxAttempts
    }

    func createInvitation(
        serviceName: String,
        serviceType: String = AgentMeterBridgeTokenStore.serviceType,
        directHost: String?,
        directPort: UInt16?,
        now: Date = Date())
        -> AgentMeterBridgePairingInvitation?
    {
        guard let sessionID = Self.randomBase64URL(byteCount: 16),
              let code = Self.randomCode(characterCount: Self.pairingCodeLength)
        else {
            return nil
        }
        let agreementKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = agreementKey.publicKey.rawRepresentation.agentMeterBase64URLEncodedString()
        guard let url = Self.invitationURL(
            serviceName: serviceName,
            serviceType: serviceType,
            sessionID: sessionID,
            publicKey: publicKey,
            directEndpoint: (directHost, directPort))
        else {
            return nil
        }
        self.lock.lock()
        self.pruneLocked(now: now)
        self.sessions[sessionID] = PendingSession(
            serviceName: serviceName,
            serviceType: serviceType,
            sessionID: sessionID,
            code: code,
            agreementKey: agreementKey,
            publicKey: publicKey,
            directHost: directHost,
            directPort: directPort,
            createdAt: now,
            attempts: 0)
        self.lock.unlock()
        return AgentMeterBridgePairingInvitation(
            serviceName: serviceName,
            serviceType: serviceType,
            sessionID: sessionID,
            publicKey: publicKey,
            code: code,
            directHost: directHost,
            directPort: directPort,
            url: url)
    }

    func complete(
        sessionID: String?,
        clientPublicKey encodedClientPublicKey: String?,
        proof: String?,
        now: Date = Date(),
        defaults: UserDefaults = .standard,
        store: any AgentMeterCredentialStoring = AgentMeterKeychainCredentialStore())
        -> Result<Data, AgentMeterBridgePairingError>
    {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              let encodedClientPublicKey = encodedClientPublicKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              let proof = proof?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty,
              !encodedClientPublicKey.isEmpty,
              !proof.isEmpty,
              let clientPublicKeyData = Data(agentMeterBase64URL: encodedClientPublicKey)
        else {
            return .failure(.invalidRequest)
        }

        self.lock.lock()
        self.pruneLocked(now: now)
        guard var session = self.sessions[sessionID] else {
            self.lock.unlock()
            return .failure(.sessionNotFound)
        }
        guard now.timeIntervalSince(session.createdAt) <= self.sessionTTL else {
            self.sessions.removeValue(forKey: sessionID)
            self.lock.unlock()
            return .failure(.sessionExpired)
        }
        guard session.attempts < self.maxAttempts else {
            self.sessions.removeValue(forKey: sessionID)
            self.lock.unlock()
            return .failure(.tooManyAttempts)
        }
        session.attempts += 1
        self.sessions[sessionID] = session
        self.lock.unlock()

        let clientPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            clientPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPublicKeyData)
        } catch {
            return .failure(.invalidRequest)
        }

        let context = AgentMeterBridgePairingCrypto.context(
            sessionID: session.sessionID,
            macPublicKey: session.publicKey,
            clientPublicKey: encodedClientPublicKey)
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try session.agreementKey.sharedSecretFromKeyAgreement(with: clientPublicKey)
        } catch {
            return .failure(.invalidRequest)
        }
        let proofKey = AgentMeterBridgePairingCrypto.derivedKey(
            from: sharedSecret,
            purpose: "proof",
            context: context)
        let expectedProof = AgentMeterBridgePairingCrypto.proof(
            code: session.code,
            key: proofKey,
            context: context)
        guard AgentMeterBridgeRequestAuth.constantTimeEquals(proof, expectedProof) else {
            return .failure(.badProof)
        }
        self.lock.lock()
        guard self.sessions.removeValue(forKey: sessionID) != nil else {
            self.lock.unlock()
            return .failure(.sessionNotFound)
        }
        self.lock.unlock()
        guard let secret = AgentMeterBridgeTokenStore.createDeviceSecret(defaults: defaults, store: store) else {
            return .failure(.keychainUnavailable)
        }

        let payload = PairingPayload(
            schemaVersion: 1,
            serviceName: session.serviceName,
            serviceType: session.serviceType,
            token: secret.token,
            deviceID: secret.deviceID,
            directHost: session.directHost,
            directPort: session.directPort)
        do {
            let payloadData = try JSONEncoder().encode(payload)
            let payloadKey = AgentMeterBridgePairingCrypto.derivedKey(
                from: sharedSecret,
                purpose: "payload",
                context: context)
            let sealed = try ChaChaPoly.seal(payloadData, using: payloadKey, authenticating: context)
            let response = PairingResponse(
                schemaVersion: 1,
                sessionID: session.sessionID,
                deviceID: secret.deviceID,
                encryptedPayload: sealed.combined.agentMeterBase64URLEncodedString())
            let responseData = try JSONEncoder().encode(response)
            return .success(responseData)
        } catch {
            return .failure(.encryptionFailed)
        }
    }

    private func pruneLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-self.sessionTTL)
        self.sessions = self.sessions.filter { $0.value.createdAt >= cutoff }
    }

    private static func invitationURL(
        serviceName: String,
        serviceType: String,
        sessionID: String,
        publicKey: String,
        directEndpoint: (host: String?, port: UInt16?))
        -> URL?
    {
        var components = URLComponents()
        components.scheme = "agentmeter"
        components.host = "pair"
        var queryItems = [
            URLQueryItem(name: "v", value: "2"),
            URLQueryItem(name: "service", value: serviceName),
            URLQueryItem(name: "type", value: serviceType),
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "macKey", value: publicKey),
        ]
        if let directHost = directEndpoint.host,
           !directHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let directPort = directEndpoint.port
        {
            queryItems.append(URLQueryItem(name: "host", value: directHost))
            queryItems.append(URLQueryItem(name: "port", value: "\(directPort)"))
        }
        components.queryItems = queryItems
        return components.url
    }

    private static func randomBase64URL(byteCount: Int) -> String? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes).agentMeterBase64URLEncodedString()
    }

    private static func randomCode(characterCount: Int) -> String? {
        guard characterCount > 0 else { return nil }
        let upperBound = UInt64(Self.pairingCodeAlphabet.count)
        let sampleSpace = UInt64(UInt8.max) + 1
        let limit = sampleSpace - (sampleSpace % upperBound)
        var result = ""
        result.reserveCapacity(characterCount)
        while result.count < characterCount {
            var value = UInt8(0)
            let status = withUnsafeMutableBytes(of: &value) { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            guard status == errSecSuccess else { return nil }
            let sample = UInt64(value)
            if sample < limit {
                result.append(Self.pairingCodeAlphabet[Int(sample % upperBound)])
            }
        }
        return result
    }
}

enum AgentMeterBridgePairingCrypto {
    private static let pairingCodeAlphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func context(sessionID: String, macPublicKey: String, clientPublicKey: String) -> Data {
        Data("AgentMeter Pairing v1\n\(sessionID)\n\(macPublicKey)\n\(clientPublicKey)".utf8)
    }

    static func derivedKey(from sharedSecret: SharedSecret, purpose: String, context: Data) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("AgentMeter Pairing \(purpose) v1".utf8),
            sharedInfo: context,
            outputByteCount: 32)
    }

    static func proof(code: String, key: SymmetricKey, context: Data) -> String {
        var message = Data("finish\n".utf8)
        message.append(context)
        message.append(Data("\n\(Self.normalizedCode(code))".utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac).agentMeterBase64URLEncodedString()
    }

    static func normalizedCode(_ raw: String) -> String {
        raw.uppercased().filter { character in
            self.pairingCodeAlphabet.contains(character)
        }
    }
}

extension Data {
    init?(agentMeterBase64URL value: String) {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: normalized)
    }

    func agentMeterBase64URLEncodedString() -> String {
        self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

import Foundation
import CryptoKit
import Network
import Security

struct AgentMeterBridgePairing: Equatable {
    static let defaultServiceType = "_agentmeter._tcp"

    let serviceName: String
    let serviceType: String
    let token: String
    let deviceID: String?
    let directHost: String?
    let directPort: UInt16?

    init?(
        serviceName: String,
        serviceType: String = Self.defaultServiceType,
        token: String,
        deviceID: String? = nil,
        directHost: String? = nil,
        directPort: UInt16? = nil)
    {
        let serviceName = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let serviceType = serviceType.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceID = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let directHost = directHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serviceName.isEmpty,
              serviceType == Self.defaultServiceType,
              token.count >= 32,
              deviceID.map(Self.isValidDeviceID) ?? true
        else {
            return nil
        }
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.token = token
        self.deviceID = deviceID?.isEmpty == false ? deviceID : nil
        self.directHost = directHost?.isEmpty == false ? directHost : nil
        self.directPort = directPort
    }

    init?(url: URL) {
        guard url.scheme == "agentmeter", url.host == "pair" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let serviceName = value("service"),
              let token = value("token")
        else {
            return nil
        }
        let directPort = value("port").flatMap(UInt16.init)
        self.init(
            serviceName: serviceName,
            serviceType: value("type") ?? Self.defaultServiceType,
            token: token,
            deviceID: value("device"),
            directHost: value("host"),
            directPort: directPort)
    }

    private static func isValidDeviceID(_ value: String) -> Bool {
        guard value.count >= 16, value.count <= 64 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

struct AgentMeterBridgePairingInvitation: Equatable {
    static let currentVersion = "2"

    let serviceName: String
    let serviceType: String
    let sessionID: String
    let macPublicKey: String
    let directHost: String?
    let directPort: UInt16?

    init?(
        serviceName: String,
        serviceType: String = AgentMeterBridgePairing.defaultServiceType,
        sessionID: String,
        macPublicKey: String,
        directHost: String? = nil,
        directPort: UInt16? = nil)
    {
        let serviceName = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let serviceType = serviceType.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let macPublicKey = macPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let directHost = directHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serviceName.isEmpty,
              serviceType == AgentMeterBridgePairing.defaultServiceType,
              Self.isValidBase64URL(sessionID, minDecodedBytes: 16),
              Self.isValidBase64URL(macPublicKey, minDecodedBytes: 32)
        else {
            return nil
        }
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.sessionID = sessionID
        self.macPublicKey = macPublicKey
        self.directHost = directHost?.isEmpty == false ? directHost : nil
        self.directPort = directPort
    }

    init?(url: URL) {
        guard url.scheme == "agentmeter", url.host == "pair" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard value("v") == Self.currentVersion,
              value("token") == nil,
              let serviceName = value("service"),
              let sessionID = value("session"),
              let macPublicKey = value("macKey")
        else {
            return nil
        }
        self.init(
            serviceName: serviceName,
            serviceType: value("type") ?? AgentMeterBridgePairing.defaultServiceType,
            sessionID: sessionID,
            macPublicKey: macPublicKey,
            directHost: value("host"),
            directPort: value("port").flatMap(UInt16.init))
    }

    private static func isValidBase64URL(_ value: String, minDecodedBytes: Int) -> Bool {
        guard value.count >= minDecodedBytes,
              value.count <= 128,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              let data = Data(agentMeterBase64URL: value)
        else {
            return false
        }
        return data.count >= minDecodedBytes
    }
}

enum AgentMeterBridgePairingStore {
    private static let keychainService = "com.zain.agentmeter.ios.bridge"
    private static let tokenAccount = "bridge-token"
    private static let serviceNameKey = "agentmeter.bridge.serviceName"
    private static let deviceIDKey = "agentmeter.bridge.deviceID"
    private static let directHostKey = "agentmeter.bridge.directHost"
    private static let directPortKey = "agentmeter.bridge.directPort"

    static func load(defaults: UserDefaults = .standard) -> AgentMeterBridgePairing? {
        guard let serviceName = defaults.string(forKey: Self.serviceNameKey),
              let token = Self.loadToken()
        else {
            return nil
        }
        let directHost = defaults.string(forKey: Self.directHostKey)
        let rawDirectPort = defaults.integer(forKey: Self.directPortKey)
        let directPort = rawDirectPort > 0 && rawDirectPort <= Int(UInt16.max) ? UInt16(rawDirectPort) : nil
        return AgentMeterBridgePairing(
            serviceName: serviceName,
            token: token,
            deviceID: defaults.string(forKey: Self.deviceIDKey),
            directHost: directHost,
            directPort: directPort)
    }

    static func save(_ pairing: AgentMeterBridgePairing, defaults: UserDefaults = .standard) throws {
        try Self.storeToken(pairing.token)
        defaults.set(pairing.serviceName, forKey: Self.serviceNameKey)
        if let deviceID = pairing.deviceID {
            defaults.set(deviceID, forKey: Self.deviceIDKey)
        } else {
            defaults.removeObject(forKey: Self.deviceIDKey)
        }
        if let directHost = pairing.directHost, let directPort = pairing.directPort {
            defaults.set(directHost, forKey: Self.directHostKey)
            defaults.set(Int(directPort), forKey: Self.directPortKey)
        } else {
            defaults.removeObject(forKey: Self.directHostKey)
            defaults.removeObject(forKey: Self.directPortKey)
        }
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Self.serviceNameKey)
        defaults.removeObject(forKey: Self.deviceIDKey)
        defaults.removeObject(forKey: Self.directHostKey)
        defaults.removeObject(forKey: Self.directPortKey)
        Self.deleteToken()
    }

    private static func loadToken() -> String? {
        var query = Self.baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else {
            return nil
        }
        return token
    }

    private static func storeToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query = Self.baseQuery()
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw AgentMeterBridgeError.keychainUnavailable
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            throw AgentMeterBridgeError.keychainUnavailable
        }
    }

    private static func deleteToken() {
        SecItemDelete(Self.baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.tokenAccount,
        ]
    }
}

enum AgentMeterBridgeError: Error, LocalizedError, Equatable {
    case notPaired
    case discoveryTimedOut
    case connectionFailed
    case unauthorized
    case badResponse
    case snapshotRejected
    case keychainUnavailable
    case pairingCodeMismatch

    var errorDescription: String? {
        switch self {
        case .notPaired:
            "Not paired"
        case .discoveryTimedOut:
            "Mac bridge not found"
        case .connectionFailed:
            "Bridge connection failed"
        case .unauthorized:
            "Pairing token rejected"
        case .badResponse:
            "Bridge response was invalid"
        case .snapshotRejected:
            "Snapshot failed validation"
        case .keychainUnavailable:
            "Keychain unavailable"
        case .pairingCodeMismatch:
            "Pairing code was not accepted"
        }
    }
}

final class AgentMeterBridgeClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.zain.agentmeter.ios.bridge")

    private struct PairingResponse: Decodable {
        let schemaVersion: Int
        let sessionID: String
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

    func fetchSnapshot(pairing: AgentMeterBridgePairing, timeout: TimeInterval = 8) async throws
        -> AgentMeterPhoneSnapshot
    {
        var directError: Error?
        if let endpoint = pairing.directEndpoint {
            do {
                let data = try await self.fetchSnapshotData(
                    endpoint: endpoint,
                    pairing: pairing,
                    timeout: timeout)
                return try self.decodeSnapshotData(data)
            } catch AgentMeterBridgeError.unauthorized {
                throw AgentMeterBridgeError.unauthorized
            } catch {
                directError = error
            }
        }
        do {
            let endpoint = try await self.discoverEndpoint(
                serviceName: pairing.serviceName,
                serviceType: pairing.serviceType,
                timeout: timeout)
            let data = try await self.fetchSnapshotData(endpoint: endpoint, pairing: pairing, timeout: timeout)
            return try self.decodeSnapshotData(data)
        } catch {
            throw directError ?? error
        }
    }

    func completePairing(
        invitation: AgentMeterBridgePairingInvitation,
        code rawCode: String,
        timeout: TimeInterval = 8)
        async throws -> AgentMeterBridgePairing
    {
        let code = AgentMeterBridgePairingCrypto.normalizedCode(rawCode)
        guard code.count == AgentMeterBridgePairingCrypto.pairingCodeLength else {
            throw AgentMeterBridgeError.pairingCodeMismatch
        }
        var directError: Error?
        if let endpoint = invitation.directEndpoint {
            do {
                return try await self.completePairing(
                    endpoint: endpoint,
                    invitation: invitation,
                    code: code,
                    timeout: timeout)
            } catch AgentMeterBridgeError.pairingCodeMismatch {
                throw AgentMeterBridgeError.pairingCodeMismatch
            } catch {
                directError = error
            }
        }
        do {
            let endpoint = try await self.discoverEndpoint(
                serviceName: invitation.serviceName,
                serviceType: invitation.serviceType,
                timeout: timeout)
            return try await self.completePairing(
                endpoint: endpoint,
                invitation: invitation,
                code: code,
                timeout: timeout)
        } catch {
            throw directError ?? error
        }
    }

    private func decodeSnapshotData(_ data: Data) throws -> AgentMeterPhoneSnapshot {
        guard !AgentMeterPhoneSnapshotStore.containsSensitiveMaterial(data) else {
            throw AgentMeterBridgeError.snapshotRejected
        }
        return try AgentMeterPhoneSnapshotStore.decoder.decode(AgentMeterPhoneSnapshot.self, from: data)
    }

    private func discoverEndpoint(serviceName: String, serviceType: String, timeout: TimeInterval) async throws
        -> NWEndpoint
    {
        try await withCheckedThrowingContinuation { continuation in
            let box = AgentMeterBridgeDiscoveryBox(
                serviceName: serviceName,
                continuation: continuation)
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
            box.browser = browser
            browser.browseResultsChangedHandler = { results, _ in
                guard let endpoint = results.map(\.endpoint).first(where: {
                    if case let .service(name, _, _, _) = $0 {
                        return name == serviceName
                    }
                    return false
                }) else {
                    return
                }
                box.succeed(endpoint)
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state {
                    box.fail(.connectionFailed)
                }
            }
            box.timeout = DispatchWorkItem {
                box.fail(.discoveryTimedOut)
            }
            self.queue.asyncAfter(deadline: .now() + timeout, execute: box.timeout!)
            browser.start(queue: self.queue)
        }
    }

    private func fetchSnapshotData(endpoint: NWEndpoint, pairing: AgentMeterBridgePairing, timeout: TimeInterval)
        async throws -> Data
    {
        let headers = AgentMeterBridgeRequestSigner.headers(
            method: "GET",
            path: "/snapshot",
            token: pairing.token)
        let request = AgentMeterBridgeHTTPRequestBuilder.snapshotRequest(
            timestamp: headers.timestamp,
            nonce: headers.nonce,
            signature: headers.signature,
            deviceID: pairing.deviceID)
        return try await self.fetchData(endpoint: endpoint, request: request, timeout: timeout)
    }

    private func completePairing(
        endpoint: NWEndpoint,
        invitation: AgentMeterBridgePairingInvitation,
        code: String,
        timeout: TimeInterval)
        async throws -> AgentMeterBridgePairing
    {
        guard let macPublicKeyData = Data(agentMeterBase64URL: invitation.macPublicKey) else {
            throw AgentMeterBridgeError.badResponse
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let clientPublicKey = privateKey.publicKey.rawRepresentation.agentMeterBase64URLEncodedString()
        let macPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            macPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: macPublicKeyData)
        } catch {
            throw AgentMeterBridgeError.badResponse
        }
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: macPublicKey)
        let context = AgentMeterBridgePairingCrypto.context(
            sessionID: invitation.sessionID,
            macPublicKey: invitation.macPublicKey,
            clientPublicKey: clientPublicKey)
        let proofKey = AgentMeterBridgePairingCrypto.derivedKey(
            from: sharedSecret,
            purpose: "proof",
            context: context)
        let proof = AgentMeterBridgePairingCrypto.proof(code: code, key: proofKey, context: context)
        let request = AgentMeterBridgeHTTPRequestBuilder.pairingFinishRequest(
            sessionID: invitation.sessionID,
            clientPublicKey: clientPublicKey,
            proof: proof)
        let data: Data
        do {
            data = try await self.fetchData(endpoint: endpoint, request: request, timeout: timeout)
        } catch AgentMeterBridgeError.unauthorized {
            throw AgentMeterBridgeError.pairingCodeMismatch
        }
        let response = try JSONDecoder().decode(PairingResponse.self, from: data)
        guard response.schemaVersion == 1,
              response.sessionID == invitation.sessionID,
              let sealedData = Data(agentMeterBase64URL: response.encryptedPayload)
        else {
            throw AgentMeterBridgeError.badResponse
        }
        let payloadKey = AgentMeterBridgePairingCrypto.derivedKey(
            from: sharedSecret,
            purpose: "payload",
            context: context)
        let sealedBox = try ChaChaPoly.SealedBox(combined: sealedData)
        let payloadData = try ChaChaPoly.open(sealedBox, using: payloadKey, authenticating: context)
        let payload = try JSONDecoder().decode(PairingPayload.self, from: payloadData)
        guard payload.schemaVersion == 1,
              payload.deviceID == response.deviceID
        else {
            throw AgentMeterBridgeError.badResponse
        }
        guard let pairing = AgentMeterBridgePairing(
            serviceName: payload.serviceName,
            serviceType: payload.serviceType,
            token: payload.token,
            deviceID: payload.deviceID,
            directHost: payload.directHost,
            directPort: payload.directPort)
        else {
            throw AgentMeterBridgeError.badResponse
        }
        return pairing
    }

    private func fetchData(endpoint: NWEndpoint, request: String, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let box = AgentMeterBridgeConnectionBox(continuation: continuation)
            let connection = NWConnection(to: endpoint, using: .tcp)
            box.connection = connection
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        if error != nil {
                            box.fail(.connectionFailed)
                        } else {
                            box.receive()
                        }
                    })
                case .failed, .cancelled:
                    box.fail(.connectionFailed)
                case .setup, .preparing, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            box.timeout = DispatchWorkItem {
                box.fail(.connectionFailed)
            }
            self.queue.asyncAfter(deadline: .now() + timeout, execute: box.timeout!)
            connection.start(queue: self.queue)
        }
    }
}

private final class AgentMeterBridgeDiscoveryBox: @unchecked Sendable {
    let serviceName: String
    var browser: NWBrowser?
    var timeout: DispatchWorkItem?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NWEndpoint, Error>?

    init(serviceName: String, continuation: CheckedContinuation<NWEndpoint, Error>) {
        self.serviceName = serviceName
        self.continuation = continuation
    }

    func succeed(_ endpoint: NWEndpoint) {
        self.complete {
            $0.resume(returning: endpoint)
        }
    }

    func fail(_ error: AgentMeterBridgeError) {
        self.complete {
            $0.resume(throwing: error)
        }
    }

    private func complete(_ resume: (CheckedContinuation<NWEndpoint, Error>) -> Void) {
        self.lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        guard let continuation else { return }
        self.timeout?.cancel()
        self.browser?.cancel()
        resume(continuation)
    }
}

enum AgentMeterBridgeHTTPRequestBuilder {
    static func snapshotRequest(
        timestamp: String,
        nonce: String,
        signature: String,
        deviceID: String?)
        -> String
    {
        var lines = [
            "GET /snapshot HTTP/1.1",
            "Host: agentmeter.local",
            "X-AgentMeter-Bridge-Timestamp: \(timestamp)",
            "X-AgentMeter-Bridge-Nonce: \(nonce)",
            "X-AgentMeter-Bridge-Signature: \(signature)",
        ]
        if let deviceID {
            lines.append("X-AgentMeter-Bridge-Device: \(deviceID)")
        }
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    static func pairingFinishRequest(sessionID: String, clientPublicKey: String, proof: String) -> String {
        var components = URLComponents()
        components.path = "/pair/finish"
        components.queryItems = [
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "clientKey", value: clientPublicKey),
            URLQueryItem(name: "proof", value: proof),
        ]
        let target = components.string ?? "/pair/finish"
        let lines = [
            "GET \(target) HTTP/1.1",
            "Host: agentmeter.local",
            "Connection: close",
            "",
            "",
        ]
        return lines.joined(separator: "\r\n")
    }
}

private final class AgentMeterBridgeConnectionBox: @unchecked Sendable {
    var connection: NWConnection?
    var timeout: DispatchWorkItem?
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, Error>?

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func receive() {
        self.connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.buffer.append(data)
            }
            if let response = Self.responsePayloadIfComplete(self.buffer) {
                switch response {
                case let .body(body):
                    self.succeed(body)
                case let .error(error):
                    self.fail(error)
                }
                return
            }
            if error != nil || isComplete {
                self.fail(.badResponse)
                return
            }
            self.receive()
        }
    }

    func succeed(_ data: Data) {
        self.complete {
            $0.resume(returning: data)
        }
    }

    func fail(_ error: AgentMeterBridgeError) {
        self.complete {
            $0.resume(throwing: error)
        }
    }

    private func complete(_ resume: (CheckedContinuation<Data, Error>) -> Void) {
        self.lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        guard let continuation else { return }
        self.timeout?.cancel()
        self.connection?.cancel()
        resume(continuation)
    }

    private static func responsePayloadIfComplete(_ data: Data) -> AgentMeterBridgeHTTPPayload? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let headerText = String(
                  data: data[..<headerRange.lowerBound],
                  encoding: .utf8)
        else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let bodyStart = headerRange.upperBound
        let contentLength = lines.compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].lowercased() == "content-length"
            else {
                return nil
            }
            return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }.first
        guard let contentLength,
              data.count - bodyStart >= contentLength
        else {
            return nil
        }
        if statusLine.contains("200") {
            return .body(data[bodyStart..<(bodyStart + contentLength)])
        }
        if statusLine.contains("401") {
            return .error(.unauthorized)
        }
        return .error(.badResponse)
    }
}

private extension AgentMeterBridgePairing {
    var directEndpoint: NWEndpoint? {
        guard let directHost,
              let directPort,
              let port = NWEndpoint.Port(rawValue: directPort)
        else {
            return nil
        }
        return .hostPort(host: NWEndpoint.Host(directHost), port: port)
    }
}

private extension AgentMeterBridgePairingInvitation {
    var directEndpoint: NWEndpoint? {
        guard let directHost,
              let directPort,
              let port = NWEndpoint.Port(rawValue: directPort)
        else {
            return nil
        }
        return .hostPort(host: NWEndpoint.Host(directHost), port: port)
    }
}

private enum AgentMeterBridgeHTTPPayload {
    case body(Data)
    case error(AgentMeterBridgeError)
}

private enum AgentMeterBridgePairingCrypto {
    static let pairingCodeLength = 12
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
            Self.pairingCodeAlphabet.contains(character)
        }
    }
}

private enum AgentMeterBridgeRequestSigner {
    static func headers(method: String, path: String, token: String) -> (timestamp: String, nonce: String, signature: String) {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = self.nonce()
        let signature = self.signature(
            method: method,
            path: path,
            timestamp: timestamp,
            nonce: nonce,
            token: token)
        return (timestamp, nonce, signature)
    }

    private static func signature(
        method: String,
        path: String,
        timestamp: String,
        nonce: String,
        token: String)
        -> String
    {
        let key = SymmetricKey(data: Data(token.utf8))
        let message = "\(method.uppercased())\n\(path)\n\(timestamp)\n\(nonce)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac).base64EncodedString()
    }

    private static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))\(Int(Date().timeIntervalSince1970))"
    }
}

private extension Data {
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

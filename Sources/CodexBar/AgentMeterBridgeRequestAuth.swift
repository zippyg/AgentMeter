import CryptoKit
import Foundation

enum AgentMeterBridgeRequestAuth {
    static let timestampHeader = "x-agentmeter-bridge-timestamp"
    static let nonceHeader = "x-agentmeter-bridge-nonce"
    static let signatureHeader = "x-agentmeter-bridge-signature"
    static let allowedClockSkew: TimeInterval = 5 * 60

    static func signature(
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

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var diff = left.count ^ right.count
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? Int(left[index]) : 0
            let r = index < right.count ? Int(right[index]) : 0
            diff |= l ^ r
        }
        return diff == 0
    }

    static func isValidNonce(_ nonce: String) -> Bool {
        guard nonce.count >= 22, nonce.count <= 128 else { return false }
        return nonce.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45
                || byte == 95
        }
    }
}

enum AgentMeterBridgeAuthorizationFailure: String, Equatable {
    case missingTimestamp
    case invalidTimestamp
    case clockSkew
    case missingNonce
    case invalidNonce
    case replayedNonce
    case missingSignature
    case badSignature
}

enum AgentMeterBridgeAuthorizationResult: Equatable {
    case allowed
    case denied(AgentMeterBridgeAuthorizationFailure)
}

final class AgentMeterBridgeRequestAuthorizer: @unchecked Sendable {
    private let lock = NSLock()
    private var seenNonces: [String: Date] = [:]

    func isAuthorized(
        method: String,
        path: String,
        headers: [String: String],
        token: String,
        now: Date = Date())
        -> Bool
    {
        self.authorizationResult(
            method: method,
            path: path,
            headers: headers,
            token: token,
            now: now) == .allowed
    }

    func authorizationResult(
        method: String,
        path: String,
        headers: [String: String],
        token: String,
        now: Date = Date())
        -> AgentMeterBridgeAuthorizationResult
    {
        guard let timestamp = headers[AgentMeterBridgeRequestAuth.timestampHeader] else {
            return .denied(.missingTimestamp)
        }
        guard let timestampSeconds = TimeInterval(timestamp) else {
            return .denied(.invalidTimestamp)
        }
        guard abs(now.timeIntervalSince1970 - timestampSeconds) <= AgentMeterBridgeRequestAuth.allowedClockSkew else {
            return .denied(.clockSkew)
        }
        guard let nonce = headers[AgentMeterBridgeRequestAuth.nonceHeader] else {
            return .denied(.missingNonce)
        }
        guard AgentMeterBridgeRequestAuth.isValidNonce(nonce) else {
            return .denied(.invalidNonce)
        }
        guard let provided = headers[AgentMeterBridgeRequestAuth.signatureHeader] else {
            return .denied(.missingSignature)
        }

        self.lock.lock()
        self.pruneLocked(now: now)
        guard self.seenNonces[nonce] == nil else {
            self.lock.unlock()
            return .denied(.replayedNonce)
        }
        let expected = AgentMeterBridgeRequestAuth.signature(
            method: method,
            path: path,
            timestamp: timestamp,
            nonce: nonce,
            token: token)
        guard AgentMeterBridgeRequestAuth.constantTimeEquals(provided, expected) else {
            self.lock.unlock()
            return .denied(.badSignature)
        }
        self.seenNonces[nonce] = now
        self.lock.unlock()
        return .allowed
    }

    private func pruneLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-AgentMeterBridgeRequestAuth.allowedClockSkew)
        self.seenNonces = self.seenNonces.filter { $0.value >= cutoff }
    }
}

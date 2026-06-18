import CodexBarCore
import Foundation
import Network

final class AgentMeterLiveSyncServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.zain.agentmeter.live-sync")
    private let fileURL: URL
    private let serviceName: String
    private let logger = CodexBarLog.logger(LogCategories.agentMeterBridge)
    private let stateLock = NSLock()
    private let authorizer = AgentMeterBridgeRequestAuthorizer()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: AgentMeterLiveSyncHTTPConnection] = [:]
    private var legacyToken: String?
    private var publishedPort: UInt16?

    init(
        fileURL: URL = AgentMeterPhoneSnapshotStore.defaultURL(),
        serviceName: String = AgentMeterBridgeTokenStore.serviceName())
    {
        self.fileURL = fileURL
        self.serviceName = serviceName
    }

    var pairingURL: URL? {
        guard let secret = AgentMeterBridgeTokenStore.createPairingSecret() else { return nil }
        self.stateLock.lock()
        let port = self.publishedPort
        self.stateLock.unlock()
        return AgentMeterBridgeTokenStore.pairingURL(
            serviceName: self.serviceName,
            token: secret.token,
            deviceID: secret.deviceID,
            directHost: AgentMeterBridgeRuntimeStore.bestHost(),
            directPort: port)
    }

    var isRunning: Bool {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.listener != nil
    }

    func start() {
        self.queue.async {
            self.startOnQueue()
        }
    }

    func stop() {
        self.stateLock.lock()
        let port = self.publishedPort
        self.publishedPort = nil
        self.stateLock.unlock()
        AgentMeterBridgeRuntimeStore.clearOwned(port: port)
        self.queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values {
                connection.cancel()
            }
            self.connections.removeAll()
            self.logger.info("AgentMeter live bridge stopped")
        }
    }

    private func startOnQueue() {
        if self.listener != nil { return }
        guard let token = self.currentToken() else {
            self.logger.error("AgentMeter live bridge could not start because its Keychain token is unavailable")
            return
        }
        self.legacyToken = token

        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.service = NWListener.Service(name: self.serviceName, type: AgentMeterBridgeTokenStore.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: self.queue)
        } catch {
            self.logger.error("AgentMeter live bridge failed to create listener: \(error.localizedDescription)")
        }
    }

    private func currentToken() -> String? {
        if let legacyToken {
            return legacyToken
        }
        return AgentMeterBridgeTokenStore.loadOrCreate()
    }

    private func tokenForRequest(deviceID: String?) -> String? {
        if let deviceID,
           !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return AgentMeterBridgeTokenStore.tokenForRequest(deviceID: deviceID)
        }
        return AgentMeterBridgeTokenStore.loadOrCreate() ?? self.legacyToken
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = self.listener?.port?.rawValue ?? 0
            if port > 0 {
                self.stateLock.lock()
                self.publishedPort = port
                self.stateLock.unlock()
                AgentMeterBridgeRuntimeStore.save(port: port)
            }
            self.logger.info(
                "AgentMeter live bridge ready",
                metadata: [
                    "port": "\(port)",
                    "serviceName": self.serviceName,
                ])
        case let .failed(error):
            self.logger.error("AgentMeter live bridge failed: \(error.localizedDescription)")
            self.listener?.cancel()
            self.listener = nil
        case .cancelled:
            self.stateLock.lock()
            let port = self.publishedPort
            self.publishedPort = nil
            self.stateLock.unlock()
            AgentMeterBridgeRuntimeStore.clearOwned(port: port)
            self.listener = nil
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let handler = AgentMeterLiveSyncHTTPConnection(
            connection: connection,
            fileURL: self.fileURL,
            tokenProvider: { [weak self] deviceID in self?.tokenForRequest(deviceID: deviceID) },
            authorizer: self.authorizer,
            onComplete: { [weak self] id in
                self?.connections.removeValue(forKey: id)
            })
        self.connections[handler.id] = handler
        handler.start(queue: self.queue)
    }
}

private final class AgentMeterLiveSyncHTTPConnection: @unchecked Sendable {
    var id: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    private let connection: NWConnection
    private let fileURL: URL
    private let tokenProvider: @Sendable (String?) -> String?
    private let authorizer: AgentMeterBridgeRequestAuthorizer
    private let onComplete: @Sendable (ObjectIdentifier) -> Void
    private var buffer = Data()
    private var finished = false

    init(
        connection: NWConnection,
        fileURL: URL,
        tokenProvider: @escaping @Sendable (String?) -> String?,
        authorizer: AgentMeterBridgeRequestAuthorizer,
        onComplete: @escaping @Sendable (ObjectIdentifier) -> Void)
    {
        self.connection = connection
        self.fileURL = fileURL
        self.tokenProvider = tokenProvider
        self.authorizer = authorizer
        self.onComplete = onComplete
    }

    func start(queue: DispatchQueue) {
        self.connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive()
            case .failed, .cancelled:
                self?.finish()
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                break
            }
        }
        self.connection.start(queue: queue)
    }

    func cancel() {
        self.connection.cancel()
        self.finish()
    }

    private func receive() {
        self.connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
            }
            if self.buffer.count > 64 * 1024 {
                self.send(.badRequest("Request too large"))
                return
            }
            if self.bufferContainsHeaderEnd {
                self.handleRequest()
                return
            }
            if error != nil {
                self.send(.badRequest("Incomplete request"))
                return
            }
            self.receive()
        }
    }

    private var bufferContainsHeaderEnd: Bool {
        self.buffer.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    private func handleRequest() {
        do {
            let request = try AgentMeterLiveSyncHTTPRequest(data: self.buffer)
            guard request.method == "GET" else {
                self.send(.methodNotAllowed("Only GET is supported"))
                return
            }
            switch request.path {
            case "/health":
                self.send(.json(["status": "ok", "service": "AgentMeter"]))
            case "/snapshot":
                guard self.isAuthorized(request: request) else {
                    self.send(.unauthorized("Pair this iPhone from the AgentMeter Mac menu"))
                    return
                }
                self.sendSnapshot()
            default:
                self.send(.notFound("Unknown AgentMeter bridge route"))
            }
        } catch {
            self.send(.badRequest("Invalid HTTP request"))
        }
    }

    private func isAuthorized(request: AgentMeterLiveSyncHTTPRequest) -> Bool {
        let deviceID = request.headers[AgentMeterBridgeTokenStore.deviceHeader]
        guard let token = self.tokenProvider(deviceID) else {
            if self.shouldWriteAuthorizationDiagnostic(request: request, deviceIDPresent: deviceID != nil) {
                self.writeAuthorizationDiagnostic(
                    result: "denied",
                    reason: "missingToken",
                    request: request,
                    deviceIDPresent: deviceID != nil)
            }
            return false
        }
        let result = self.authorizer.authorizationResult(
            method: request.method,
            path: request.path,
            headers: request.headers,
            token: token)
        switch result {
        case .allowed:
            self.writeAuthorizationDiagnostic(
                result: "allowed",
                reason: nil,
                request: request,
                deviceIDPresent: deviceID != nil)
            return true
        case let .denied(reason):
            if self.shouldWriteAuthorizationDiagnostic(request: request, deviceIDPresent: deviceID != nil) {
                self.writeAuthorizationDiagnostic(
                    result: "denied",
                    reason: reason.rawValue,
                    request: request,
                    deviceIDPresent: deviceID != nil)
            }
            return false
        }
    }

    private func shouldWriteAuthorizationDiagnostic(
        request: AgentMeterLiveSyncHTTPRequest,
        deviceIDPresent: Bool)
        -> Bool
    {
        deviceIDPresent
            || request.headers[AgentMeterBridgeRequestAuth.timestampHeader] != nil
            || request.headers[AgentMeterBridgeRequestAuth.nonceHeader] != nil
            || request.headers[AgentMeterBridgeRequestAuth.signatureHeader] != nil
    }

    private func writeAuthorizationDiagnostic(
        result: String,
        reason: String,
        request: AgentMeterLiveSyncHTTPRequest,
        deviceIDPresent: Bool)
    {
        self.writeAuthorizationDiagnostic(
            result: result,
            reason: Optional(reason),
            request: request,
            deviceIDPresent: deviceIDPresent)
    }

    private func writeAuthorizationDiagnostic(
        result: String,
        reason: String?,
        request: AgentMeterLiveSyncHTTPRequest,
        deviceIDPresent: Bool)
    {
        let url = self.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("bridge-auth-diagnostics.json")
        let timestampAgeSeconds = request.headers[AgentMeterBridgeRequestAuth.timestampHeader]
            .flatMap(TimeInterval.init)
            .map { Int(Date().timeIntervalSince1970 - $0) }
        var payload: [String: Any] = [
            "schemaVersion": 1,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "result": result,
            "method": request.method,
            "path": request.path,
            "deviceIDPresent": deviceIDPresent,
        ]
        if let reason {
            payload["reason"] = reason
        }
        if let timestampAgeSeconds {
            payload["timestampAgeSeconds"] = timestampAgeSeconds
        }
        if let nonceLength = request.headers[AgentMeterBridgeRequestAuth.nonceHeader]?.count {
            payload["nonceLength"] = nonceLength
        }
        if let signatureLength = request.headers[AgentMeterBridgeRequestAuth.signatureHeader]?.count {
            payload["signatureLength"] = signatureLength
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else {
            return
        }
        do {
            try AgentMeterFileSecurity.ensurePrivateDirectory(url.deletingLastPathComponent())
            try data.write(to: url, options: [.atomic])
            try AgentMeterFileSecurity.applyPrivateFilePermissions(url)
        } catch {
            return
        }
    }

    private func sendSnapshot() {
        do {
            let data = try Data(contentsOf: self.fileURL)
            guard !AgentMeterPhoneSnapshotStore.containsSensitiveMaterial(data) else {
                self.send(.serverError("Snapshot failed the AgentMeter secret scan"))
                return
            }
            _ = try AgentMeterPhoneSnapshotStore.decoder.decode(AgentMeterPhoneSnapshot.self, from: data)
            self.send(.ok(data, contentType: "application/json; charset=utf-8"))
        } catch {
            self.send(.serverError("No sanitized AgentMeter snapshot is available yet"))
        }
    }

    private func send(_ response: AgentMeterLiveSyncHTTPResponse) {
        if self.finished { return }
        self.connection.send(content: response.data, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.finish()
        })
    }

    private func finish() {
        if self.finished { return }
        self.finished = true
        self.onComplete(self.id)
    }
}

private struct AgentMeterLiveSyncHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]

    init(data: Data) throws {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n")
        else {
            throw AgentMeterLiveSyncHTTPRequestError.invalid
        }
        let headerBlock = String(raw[..<headerEnd.lowerBound])
        var lines = headerBlock.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw AgentMeterLiveSyncHTTPRequestError.invalid
        }
        lines.removeFirst()
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            throw AgentMeterLiveSyncHTTPRequestError.invalid
        }
        self.method = String(requestParts[0]).uppercased()
        self.path = URLComponents(string: String(requestParts[1]))?.path ?? String(requestParts[1])
        var parsedHeaders: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                parsedHeaders[key] = value
            }
        }
        self.headers = parsedHeaders
    }
}

private enum AgentMeterLiveSyncHTTPRequestError: Error {
    case invalid
}

private struct AgentMeterLiveSyncHTTPResponse {
    let data: Data

    static func ok(_ body: Data, contentType: String) -> AgentMeterLiveSyncHTTPResponse {
        self.response(code: 200, reason: "OK", body: body, contentType: contentType)
    }

    static func json(_ values: [String: String]) -> AgentMeterLiveSyncHTTPResponse {
        let body = (try? JSONEncoder().encode(values)) ?? Data("{}".utf8)
        return self.ok(body, contentType: "application/json; charset=utf-8")
    }

    static func badRequest(_ message: String) -> AgentMeterLiveSyncHTTPResponse {
        self.error(code: 400, reason: "Bad Request", message: message)
    }

    static func unauthorized(_ message: String) -> AgentMeterLiveSyncHTTPResponse {
        self.error(code: 401, reason: "Unauthorized", message: message)
    }

    static func notFound(_ message: String) -> AgentMeterLiveSyncHTTPResponse {
        self.error(code: 404, reason: "Not Found", message: message)
    }

    static func methodNotAllowed(_ message: String) -> AgentMeterLiveSyncHTTPResponse {
        self.error(code: 405, reason: "Method Not Allowed", message: message)
    }

    static func serverError(_ message: String) -> AgentMeterLiveSyncHTTPResponse {
        self.error(code: 503, reason: "Service Unavailable", message: message)
    }

    private static func error(code: Int, reason: String, message: String) -> AgentMeterLiveSyncHTTPResponse {
        let body = (try? JSONEncoder().encode(["error": message])) ?? Data("{}".utf8)
        return self.response(code: code, reason: reason, body: body, contentType: "application/json; charset=utf-8")
    }

    private static func response(
        code: Int,
        reason: String,
        body: Data,
        contentType: String)
        -> AgentMeterLiveSyncHTTPResponse
    {
        var headers = "HTTP/1.1 \(code) \(reason)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(body.count)\r\n"
        headers += "Cache-Control: no-store\r\n"
        headers += "Connection: close\r\n"
        headers += "\r\n"
        var data = Data(headers.utf8)
        data.append(body)
        return AgentMeterLiveSyncHTTPResponse(data: data)
    }
}

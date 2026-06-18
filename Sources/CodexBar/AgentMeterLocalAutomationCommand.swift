import CodexBarCore
import Foundation

enum AgentMeterLocalAutomationCommand {
    static let enabledKey = "AGENTMETER_ENABLE_LOCAL_AUTOMATION"
    static let openSimulatorPairingFlag = "--agentmeter-open-simulator-pairing"
    static let launchSimulatorPairingFlag = "--agentmeter-launch-simulator-pairing"
    static let checkBridgeAuthFlag = "--agentmeter-check-bridge-auth"
    static let defaultSimulatorBundleID = "com.zain.agentmeter.ios.dev"

    struct Request: Equatable {
        enum Action: Equatable {
            case openURL
            case launchApp(bundleID: String)
            case checkBridgeAuth
        }

        let simulatorID: String?
        let action: Action
    }

    static func request(arguments: [String], environment: [String: String]) -> Request? {
        guard self.isEnabled(environment[self.enabledKey]) else { return nil }

        if arguments.contains(self.checkBridgeAuthFlag) {
            return Request(simulatorID: nil, action: .checkBridgeAuth)
        }

        if let flagIndex = arguments.firstIndex(of: openSimulatorPairingFlag),
           arguments.indices.contains(flagIndex + 1)
        {
            let simulatorID = arguments[flagIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValidSimulatorID(simulatorID) else { return nil }
            return Request(simulatorID: simulatorID, action: .openURL)
        }

        if let flagIndex = arguments.firstIndex(of: Self.launchSimulatorPairingFlag),
           arguments.indices.contains(flagIndex + 1)
        {
            let simulatorID = arguments[flagIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            let bundleID = arguments.indices.contains(flagIndex + 2)
                ? arguments[flagIndex + 2].trimmingCharacters(in: .whitespacesAndNewlines)
                : Self.defaultSimulatorBundleID
            guard Self.isValidSimulatorID(simulatorID),
                  Self.isValidBundleID(bundleID)
            else {
                return nil
            }
            return Request(simulatorID: simulatorID, action: .launchApp(bundleID: bundleID))
        }

        return nil
    }

    static func executeIfRequested(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        portProvider: () -> UInt16? = { AgentMeterBridgeRuntimeStore.activePort() },
        pairingProvider: (UInt16) -> SimulatorPairingPayload? = Self.makeSimulatorPairingPayload(port:),
        openURL: (String, URL) -> Int32 = Self.openSimulatorURL(simulatorID:url:),
        launchApp: (String, String, String) -> Int32 = Self.launchSimulatorApp(simulatorID:bundleID:encodedPairing:),
        checkBridgeAuth: (UInt16) -> Int32 = Self.checkBridgeAuth(port:))
        -> Int32?
    {
        guard let request = Self.request(arguments: arguments, environment: environment) else {
            return nil
        }
        guard let port = portProvider() else {
            Self.writeError("AgentMeter bridge port is not available. Launch the Mac app first.")
            return 65
        }
        if request.action == .checkBridgeAuth {
            return checkBridgeAuth(port)
        }
        guard let payload = pairingProvider(port) else {
            Self.writeError("AgentMeter could not create a simulator pairing payload.")
            return 66
        }
        switch request.action {
        case .openURL:
            guard let simulatorID = request.simulatorID else { return 64 }
            guard let url = payload.url else {
                Self.writeError("AgentMeter could not create a simulator pairing URL.")
                return 66
            }
            return openURL(simulatorID, url)
        case let .launchApp(bundleID):
            guard let simulatorID = request.simulatorID else { return 64 }
            return launchApp(simulatorID, bundleID, payload.encoded)
        case .checkBridgeAuth:
            return checkBridgeAuth(port)
        }
    }

    struct SimulatorPairingPayload: Codable, Equatable {
        let serviceName: String
        let token: String
        let deviceID: String?
        let directHost: String
        let directPort: UInt16

        var encoded: String {
            (try? JSONEncoder().encode(self).base64EncodedString()) ?? ""
        }

        var url: URL? {
            AgentMeterBridgeTokenStore.pairingURL(
                serviceName: self.serviceName,
                token: self.token,
                deviceID: self.deviceID,
                directHost: self.directHost,
                directPort: self.directPort)
        }
    }

    private static func makeSimulatorPairingPayload(port: UInt16) -> SimulatorPairingPayload? {
        guard let token = AgentMeterBridgeTokenStore.loadOrCreate() else { return nil }
        return SimulatorPairingPayload(
            serviceName: AgentMeterBridgeTokenStore.serviceName(),
            token: token,
            deviceID: nil,
            directHost: "127.0.0.1",
            directPort: port)
    }

    private static func openSimulatorURL(simulatorID: String, url: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "openurl", simulatorID, url.absoluteString]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            Self.writeError("AgentMeter could not open the simulator pairing URL.")
            return 67
        }
    }

    private static func launchSimulatorApp(simulatorID: String, bundleID: String, encodedPairing: String) -> Int32 {
        guard !encodedPairing.isEmpty else { return 66 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "simctl",
            "launch",
            "--terminate-running-process",
            simulatorID,
            bundleID,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["SIMCTL_CHILD_AGENTMETER_SIMULATOR_PAIRING"] = encodedPairing
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            Self.writeError("AgentMeter could not launch the simulator app for pairing.")
            return 68
        }
    }

    private static func checkBridgeAuth(port: UInt16) -> Int32 {
        guard let token = AgentMeterBridgeTokenStore.loadOrCreate(),
              let url = URL(string: "http://127.0.0.1:\(port)/snapshot")
        else {
            self.writeError("AgentMeter bridge token is unavailable.")
            return 69
        }
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let signature = AgentMeterBridgeRequestAuth.signature(
            method: "GET",
            path: "/snapshot",
            timestamp: timestamp,
            nonce: nonce,
            token: token)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.setValue(timestamp, forHTTPHeaderField: AgentMeterBridgeRequestAuth.timestampHeader)
        request.setValue(nonce, forHTTPHeaderField: AgentMeterBridgeRequestAuth.nonceHeader)
        request.setValue(signature, forHTTPHeaderField: AgentMeterBridgeRequestAuth.signatureHeader)

        let semaphore = DispatchSemaphore(value: 0)
        let status = LockedStatus()
        URLSession.shared.dataTask(with: request) { _, response, error in
            if error != nil {
                status.value = 72
            } else if let http = response as? HTTPURLResponse {
                status.value = http.statusCode == 200 ? 0 : Int32(http.statusCode)
            } else {
                status.value = 73
            }
            semaphore.signal()
        }.resume()
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return 74
        }
        if status.value == 0 {
            return 0
        }
        Self.writeError("AgentMeter bridge auth probe failed with status \(status.value).")
        return status.value
    }

    private static func isEnabled(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled":
            return true
        default:
            return false
        }
    }

    private static func isValidSimulatorID(_ value: String) -> Bool {
        if value == "booted" { return true }
        guard value.count >= 16, value.count <= 64 else { return false }
        return value.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-"
        }
    }

    private static func isValidBundleID(_ value: String) -> Bool {
        guard value.count >= 3, value.count <= 255 else { return false }
        return value.allSatisfy { character in
            character.isLetter || character.isNumber || character == "." || character == "-"
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private final class LockedStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var rawValue: Int32 = 73

    var value: Int32 {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.rawValue
        }
        set {
            self.lock.lock()
            self.rawValue = newValue
            self.lock.unlock()
        }
    }
}

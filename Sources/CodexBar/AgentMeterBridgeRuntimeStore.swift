import Darwin
import Foundation

enum AgentMeterBridgeRuntimeStore {
    private static let portKey = "agentMeterBridgePort"
    private static let ownerPIDKey = "agentMeterBridgeOwnerPID"

    static func save(port: UInt16, processID: pid_t = getpid(), defaults: UserDefaults = .standard) {
        defaults.set(Int(port), forKey: self.portKey)
        defaults.set(Int(processID), forKey: self.ownerPIDKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: self.portKey)
        defaults.removeObject(forKey: self.ownerPIDKey)
    }

    static func clearOwned(
        port expectedPort: UInt16? = nil,
        processID: pid_t = getpid(),
        defaults: UserDefaults = .standard)
    {
        if let expectedPort,
           currentPort(defaults: defaults) != expectedPort
        {
            return
        }
        let ownerPID = defaults.integer(forKey: Self.ownerPIDKey)
        guard ownerPID == 0 || ownerPID == Int(processID) else { return }
        Self.clear(defaults: defaults)
    }

    static func currentPort(defaults: UserDefaults = .standard) -> UInt16? {
        let raw = defaults.integer(forKey: Self.portKey)
        guard raw > 0, raw <= Int(UInt16.max) else { return nil }
        return UInt16(raw)
    }

    static func activePort(
        defaults: UserDefaults = .standard,
        processIsRunning: (pid_t) -> Bool = Self.isProcessRunning,
        legacyHealthProbe: (UInt16) -> Bool = Self.legacyHealthProbe(port:))
        -> UInt16?
    {
        guard let port = currentPort(defaults: defaults) else { return nil }
        let ownerPID = defaults.integer(forKey: Self.ownerPIDKey)
        if ownerPID > 0 {
            guard processIsRunning(pid_t(ownerPID)),
                  legacyHealthProbe(port)
            else {
                return nil
            }
            return port
        }
        return legacyHealthProbe(port) ? port : nil
    }

    static func bestHost() -> String? {
        if let address = firstNonLoopbackIPv4Address() {
            return address
        }
        let hostName = ProcessInfo.processInfo.hostName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return hostName.isEmpty ? nil : hostName
    }

    private static func firstNonLoopbackIPv4Address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST)
            guard result == 0 else { continue }
            let endIndex = host.firstIndex(of: 0) ?? host.endIndex
            let bytes = host[..<endIndex].map { UInt8(bitPattern: $0) }
            guard let candidate = String(bytes: bytes, encoding: .utf8) else { continue }
            if !candidate.hasPrefix("169.254.") {
                return candidate
            }
        }
        return nil
    }

    private static func isProcessRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func legacyHealthProbe(port: UInt16) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedBool()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data,
                  let body = String(data: data, encoding: .utf8)
            else {
                return
            }
            result.value = body.contains("\"service\":\"AgentMeter\"") ||
                body.contains("\"service\": \"AgentMeter\"")
        }.resume()
        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            return false
        }
        return result.value
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var rawValue = false

    var value: Bool {
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

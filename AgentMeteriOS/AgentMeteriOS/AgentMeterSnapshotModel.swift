import Foundation
import WidgetKit

@MainActor
final class AgentMeterSnapshotModel: ObservableObject {
    @Published private(set) var snapshot: AgentMeterPhoneSnapshot
    @Published private(set) var sourceMessage: String
    @Published private(set) var bridgeMessage: String
    @Published private(set) var pendingPairingInvitation: AgentMeterBridgePairingInvitation?
    @Published private(set) var isCompletingPairing = false

    private let fileURL: URL
    private let bridgeClient = AgentMeterBridgeClient()
    private var bridgeTask: Task<Void, Never>?

    init(fileURL: URL = AgentMeterPhoneSnapshotStore.defaultURL()) {
        #if targetEnvironment(simulator)
        AgentMeterSimulatorPairingBootstrap.applyIfPresent()
        #endif
        self.fileURL = fileURL
        let result = AgentMeterPhoneSnapshotStore.loadOrSample(fileURL: fileURL)
        self.snapshot = result.snapshot
        self.sourceMessage = Self.message(for: result.source)
        self.bridgeMessage = AgentMeterBridgePairingStore.load() == nil
            ? "Mac bridge not paired"
            : "Mac bridge paired"
    }

    func refresh() {
        let result = AgentMeterPhoneSnapshotStore.loadOrSample(fileURL: self.fileURL)
        self.snapshot = result.snapshot
        self.sourceMessage = Self.message(for: result.source)
    }

    func startBridgeSync() {
        guard self.bridgeTask == nil else { return }
        self.bridgeTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.syncFromBridge()
                let delay = self.nextBridgeSyncDelay()
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stopBridgeSync() {
        self.bridgeTask?.cancel()
        self.bridgeTask = nil
    }

    func refreshFromBridgeOrCache() {
        Task {
            let synced = await self.syncFromBridge()
            if !synced {
                self.refresh()
            }
        }
    }

    @discardableResult
    func handlePairingURL(_ url: URL) -> Bool {
        if let invitation = AgentMeterBridgePairingInvitation(url: url) {
            self.pendingPairingInvitation = invitation
            self.bridgeMessage = "Enter Mac pairing code"
            return true
        }
        guard let pairing = AgentMeterBridgePairing(url: url) else { return false }
        do {
            try AgentMeterBridgePairingStore.save(pairing)
            self.bridgeMessage = "Paired to \(pairing.serviceName)"
            self.startBridgeSync()
            Task { await self.syncFromBridge() }
            return true
        } catch {
            self.bridgeMessage = "Pairing failed"
            return false
        }
    }

    func cancelPendingPairing() {
        self.pendingPairingInvitation = nil
        if AgentMeterBridgePairingStore.load() == nil {
            self.bridgeMessage = "Mac bridge not paired"
        }
    }

    func completePendingPairing(code: String) {
        guard let invitation = self.pendingPairingInvitation,
              !self.isCompletingPairing
        else {
            return
        }
        self.isCompletingPairing = true
        self.bridgeMessage = "Pairing \(invitation.serviceName)"
        Task { @MainActor in
            defer { self.isCompletingPairing = false }
            do {
                let pairing = try await self.bridgeClient.completePairing(invitation: invitation, code: code)
                try AgentMeterBridgePairingStore.save(pairing)
                self.pendingPairingInvitation = nil
                self.bridgeMessage = "Paired to \(pairing.serviceName)"
                self.startBridgeSync()
                await self.syncFromBridge()
            } catch {
                self.bridgeMessage = Self.bridgeMessage(for: error)
            }
        }
    }

    @discardableResult
    func importSnapshot(from url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            self.snapshot = try AgentMeterPhoneSnapshotStore.importSnapshot(from: url, fileURL: self.fileURL)
            self.sourceMessage = "Imported snapshot"
            return true
        } catch {
            self.sourceMessage = "Import failed"
            return false
        }
    }

    @discardableResult
    private func syncFromBridge() async -> Bool {
        guard let pairing = AgentMeterBridgePairingStore.load() else {
            self.bridgeMessage = "Mac bridge not paired"
            return false
        }
        self.bridgeMessage = "Syncing \(pairing.serviceName)"
        do {
            let snapshot = try await self.bridgeClient.fetchSnapshot(pairing: pairing)
            try AgentMeterPhoneSnapshotStore.save(snapshot, fileURL: self.fileURL)
            self.snapshot = snapshot
            self.sourceMessage = "Mac bridge live"
            self.bridgeMessage = "Live from \(pairing.serviceName)"
            WidgetCenter.shared.reloadAllTimelines()
            return true
        } catch {
            self.bridgeMessage = Self.bridgeMessage(for: error)
            self.refresh()
            return false
        }
    }

    private func nextBridgeSyncDelay() -> TimeInterval {
        let nextRefresh = self.snapshot.providers.compactMap(\.nextRefreshAt).min()
        guard let nextRefresh else { return 60 }
        let seconds = nextRefresh.timeIntervalSinceNow
        return min(max(seconds, 30), 300)
    }

    private static func message(for source: AgentMeterPhoneSnapshotSource) -> String {
        switch source {
        case .cache:
            "Local snapshot cache"
        case .missing:
            "No Mac snapshot imported"
        case .sample:
            "Sample data"
        }
    }

    private static func bridgeMessage(for error: Error) -> String {
        guard let bridgeError = error as? AgentMeterBridgeError else {
            return "Bridge unavailable"
        }
        switch bridgeError {
        case .notPaired:
            return "Mac bridge not paired"
        case .discoveryTimedOut:
            return "Mac bridge not found"
        case .connectionFailed:
            return "Bridge connection failed"
        case .unauthorized:
            return "Bridge token rejected"
        case .badResponse:
            return "Bridge response invalid"
        case .snapshotRejected:
            return "Snapshot rejected"
        case .keychainUnavailable:
            return "Keychain unavailable"
        case .pairingCodeMismatch:
            return "Pairing code rejected"
        }
    }
}

#if targetEnvironment(simulator)
private enum AgentMeterSimulatorPairingBootstrap {
    private static let environmentKey = "AGENTMETER_SIMULATOR_PAIRING"
    private static let resultKey = "agentmeter.bridge.simulatorBootstrapResult"

    private struct Payload: Decodable {
        let serviceName: String
        let token: String
        let deviceID: String?
        let directHost: String
        let directPort: UInt16
    }

    static func applyIfPresent(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let encoded = environment[Self.environmentKey],
              let data = Data(base64Encoded: encoded),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let pairing = AgentMeterBridgePairing(
                  serviceName: payload.serviceName,
                  token: payload.token,
                  deviceID: payload.deviceID,
                  directHost: payload.directHost,
                  directPort: payload.directPort)
        else {
            return
        }
        let defaults = UserDefaults.standard
        AgentMeterBridgePairingStore.clear(defaults: defaults)
        do {
            try AgentMeterBridgePairingStore.save(pairing, defaults: defaults)
            let loaded = AgentMeterBridgePairingStore.load(defaults: defaults)
            defaults.set(loaded?.token == pairing.token ? "saved" : "tokenMismatchAfterSave", forKey: Self.resultKey)
        } catch {
            defaults.set("saveFailed", forKey: Self.resultKey)
        }
    }
}
#endif

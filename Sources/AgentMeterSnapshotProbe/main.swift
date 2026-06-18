import CodexBarCore
import Foundation

#if os(macOS)
final class ProbeObserver: NSObject {
    private let expectedPath: String?
    private(set) var userInfo: [AnyHashable: Any]?

    init(expectedPath: String?) {
        self.expectedPath = expectedPath
    }

    @objc func receive(_ notification: Notification) {
        let userInfo = notification.userInfo ?? [:]
        if let expectedPath,
           userInfo["path"] as? String != expectedPath
        {
            return
        }
        self.userInfo = userInfo
    }
}
#endif

enum AgentMeterSnapshotProbe {
    static func main() {
        #if os(macOS)
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            print(Self.help)
            Foundation.exit(0)
        }

        let timeout = Self.timeout(from: args)
        let waitOnly = args.contains("--wait-only")
        let fileURL = Self.fileURL(from: args, waitOnly: waitOnly)
        let observer = ProbeObserver(expectedPath: waitOnly ? nil : fileURL.path)
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            observer,
            selector: #selector(ProbeObserver.receive(_:)),
            name: Notification.Name(AgentMeterSnapshotNotification.name),
            object: nil,
            suspensionBehavior: .deliverImmediately)
        defer { center.removeObserver(observer) }

        if !waitOnly {
            do {
                try AgentMeterSnapshotStore.save(Self.fixtureSnapshot(), fileURL: fileURL)
            } catch {
                Self.fail("failed to write probe snapshot: \(error.localizedDescription)")
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while observer.userInfo == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        guard let userInfo = observer.userInfo else {
            if !waitOnly, FileManager.default.fileExists(atPath: fileURL.path) {
                Self.fail(
                    "snapshot was written but \(AgentMeterSnapshotNotification.name) was not observed. "
                        + "If this ran inside Codex or another sandbox, rerun it from normal Terminal.")
            }
            Self.fail("timed out waiting for \(AgentMeterSnapshotNotification.name)")
        }

        guard let schemaVersion = userInfo["schemaVersion"] as? Int,
              let snapshotSequence = userInfo["snapshotSequence"] as? Int,
              let generatedAt = userInfo["generatedAt"] as? String,
              let path = userInfo["path"] as? String,
              !generatedAt.isEmpty
        else {
            Self.fail("notification userInfo was missing required sanitized fields")
        }

        print("AgentMeter snapshot notification observed")
        print("name=\(AgentMeterSnapshotNotification.name)")
        print("path=\(path)")
        print("schemaVersion=\(schemaVersion)")
        print("snapshotSequence=\(snapshotSequence)")
        print("generatedAt=\(generatedAt)")
        Foundation.exit(0)
        #else
        Self.fail("AgentMeter snapshot notifications are macOS-only")
        #endif
    }

    private static var help: String {
        """
        Usage:
          AgentMeterSnapshotProbe [--timeout <seconds>] [--file <path>] [--wait-only]

        Description:
          Proves the same-Mac AgentMeter snapshot notification path. By default it writes a sanitized
          temporary snapshot through AgentMeterSnapshotStore and waits for
          com.zain.agentmeter.snapshot.updated. With --wait-only it only listens for a live app update.
        """
    }

    private static func timeout(from args: [String]) -> TimeInterval {
        guard let index = args.firstIndex(of: "--timeout"),
              args.indices.contains(args.index(after: index)),
              let value = TimeInterval(args[args.index(after: index)]),
              value > 0
        else {
            return 3
        }
        return value
    }

    private static func fileURL(from args: [String], waitOnly: Bool) -> URL {
        if let index = args.firstIndex(of: "--file"),
           args.indices.contains(args.index(after: index))
        {
            return URL(fileURLWithPath: args[args.index(after: index)])
        }
        if waitOnly {
            return AgentMeterSnapshotStore.defaultURL()
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-snapshot-probe-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(AgentMeterSnapshotStore.filename, isDirectory: false)
    }

    private static func fixtureSnapshot() -> AgentMeterSnapshot {
        AgentMeterSnapshot(
            snapshotSequence: 1,
            generatedAt: Date(),
            producer: AgentMeterSnapshotProducer(
                bundleIdentifier: "com.zain.agentmeter.snapshot-probe",
                displayName: "AgentMeterSnapshotProbe"),
            providers: [
                AgentMeterProviderSnapshot(
                    id: "codex",
                    displayName: "Codex",
                    windows: [
                        AgentMeterUsageWindow(
                            id: "session",
                            title: "Session",
                            usedPercent: 1,
                            remainingPercent: 99,
                            resetsAt: nil,
                            resetDescription: nil,
                            windowMinutes: 300),
                    ],
                    source: AgentMeterSourceDescriptor(
                        confidence: .local,
                        label: "AgentMeter probe"),
                    status: .ok,
                    updatedAt: Date(),
                    staleAfter: Date().addingTimeInterval(60)),
            ])
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
        Foundation.exit(1)
    }
}

AgentMeterSnapshotProbe.main()

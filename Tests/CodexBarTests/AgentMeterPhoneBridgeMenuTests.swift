import Foundation
import Testing
@testable import AgentMeter

@MainActor
struct AgentMeterPhoneBridgeMenuTests {
    @Test
    func `phone snapshot submenu exposes copy path and disabled reveal when file is missing`() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-phone-bridge-menu-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("agentmeter-phone-snapshot.json", isDirectory: false)

        let section = MenuDescriptor.phoneSnapshotSection(fileURL: fileURL, fileExists: false)
        let submenu = try #require(section.entries.onlySubmenu)

        #expect(submenu.title == "iPhone Snapshot")
        #expect(submenu.systemImageName == "iphone")
        #expect(submenu.items.map(\.title) == [
            "Copy Snapshot Path",
            "Copy Pairing Link (Sensitive)",
            "Export Snapshot...",
            "Reveal Snapshot in Finder",
        ])
        #expect(submenu.items[0].action == .copyPhoneSnapshotPath)
        #expect(submenu.items[0].isEnabled)
        #expect(submenu.items[1].action == .copyPhonePairingURL)
        #expect(submenu.items[1].isEnabled)
        #expect(submenu.items[2].action == .exportPhoneSnapshot)
        #expect(!submenu.items[2].isEnabled)
        #expect(submenu.items[3].action == .revealPhoneSnapshot)
        #expect(!submenu.items[3].isEnabled)
    }

    @Test
    func `phone snapshot submenu enables reveal when file exists`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-phone-bridge-menu-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("agentmeter-phone-snapshot.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: fileURL)

        let section = MenuDescriptor.phoneSnapshotSection(fileURL: fileURL)
        let submenu = try #require(section.entries.onlySubmenu)

        #expect(submenu.items[2].action == .exportPhoneSnapshot)
        #expect(submenu.items[2].isEnabled)
        #expect(submenu.items[3].action == .revealPhoneSnapshot)
        #expect(submenu.items[3].isEnabled)
    }
}

extension [MenuDescriptor.Entry] {
    var onlySubmenu: (title: String, systemImageName: String?, items: [MenuDescriptor.SubmenuItem])? {
        guard self.count == 1 else { return nil }
        guard case let .submenu(title, systemImageName, items) = self[0] else { return nil }
        return (title, systemImageName, items)
    }
}

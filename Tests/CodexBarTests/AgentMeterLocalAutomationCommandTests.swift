import Foundation
import Testing
@testable import AgentMeter

struct AgentMeterLocalAutomationCommandTests {
    @Test
    func `local automation ignores pairing command until explicitly enabled`() {
        let request = AgentMeterLocalAutomationCommand.request(
            arguments: ["AgentMeter", "--agentmeter-open-simulator-pairing", "booted"],
            environment: [:])

        #expect(request == nil)
    }

    @Test
    func `local automation accepts booted simulator pairing target when enabled`() throws {
        let request = try #require(AgentMeterLocalAutomationCommand.request(
            arguments: ["AgentMeter", "--agentmeter-open-simulator-pairing", "booted"],
            environment: ["AGENTMETER_ENABLE_LOCAL_AUTOMATION": "1"]))

        #expect(request.simulatorID == "booted")
        #expect(request.action == .openURL)
    }

    @Test
    func `local automation accepts simulator launch pairing target when enabled`() throws {
        let request = try #require(AgentMeterLocalAutomationCommand.request(
            arguments: [
                "AgentMeter",
                "--agentmeter-launch-simulator-pairing",
                "653DB19C-D9A5-4F3A-91D5-DEF98DBC8CAE",
                "com.zain.agentmeter.ios.dev",
            ],
            environment: ["AGENTMETER_ENABLE_LOCAL_AUTOMATION": "1"]))

        #expect(request.simulatorID == "653DB19C-D9A5-4F3A-91D5-DEF98DBC8CAE")
        #expect(request.action == .launchApp(bundleID: "com.zain.agentmeter.ios.dev"))
    }

    @Test
    func `local automation accepts bridge auth probe when enabled`() throws {
        let request = try #require(AgentMeterLocalAutomationCommand.request(
            arguments: ["AgentMeter", "--agentmeter-check-bridge-auth"],
            environment: ["AGENTMETER_ENABLE_LOCAL_AUTOMATION": "1"]))

        #expect(request.simulatorID == nil)
        #expect(request.action == .checkBridgeAuth)
    }

    @Test
    func `local automation rejects malformed simulator target`() {
        let request = AgentMeterLocalAutomationCommand.request(
            arguments: ["AgentMeter", "--agentmeter-open-simulator-pairing", "../bad"],
            environment: ["AGENTMETER_ENABLE_LOCAL_AUTOMATION": "1"])

        #expect(request == nil)
    }

    @Test
    func `local automation opens generated pairing URL without exposing token to test output`() {
        var opened: (simulatorID: String, url: URL)?
        let fakePayload = AgentMeterLocalAutomationCommand.SimulatorPairingPayload(
            serviceName: "test",
            token: String(repeating: "a", count: 48),
            deviceID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            directHost: "127.0.0.1",
            directPort: 54042)

        let exitCode = AgentMeterLocalAutomationCommand.executeIfRequested(
            arguments: ["AgentMeter", "--agentmeter-open-simulator-pairing", "653DB19C-D9A5-4F3A-91D5-DEF98DBC8CAE"],
            environment: ["AGENTMETER_ENABLE_LOCAL_AUTOMATION": "1"],
            portProvider: { 54042 },
            pairingProvider: { port in
                #expect(port == 54042)
                return fakePayload
            },
            openURL: { simulatorID, url in
                opened = (simulatorID, url)
                return 0
            },
            launchApp: { _, _, _ in
                Issue.record("launchApp must not be called for open URL pairing")
                return 1
            },
            checkBridgeAuth: { _ in
                Issue.record("checkBridgeAuth must not be called for open URL pairing")
                return 1
            })

        #expect(exitCode == 0)
        #expect(opened?.simulatorID == "653DB19C-D9A5-4F3A-91D5-DEF98DBC8CAE")
        #expect(opened?.url == fakePayload.url)
    }

    @Test
    func `local automation launches simulator app with encoded pairing`() throws {
        var launched: (simulatorID: String, bundleID: String, encoded: String)?
        let payload = AgentMeterLocalAutomationCommand.SimulatorPairingPayload(
            serviceName: "AgentMeter Test",
            token: String(repeating: "b", count: 48),
            deviceID: "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee",
            directHost: "127.0.0.1",
            directPort: 54042)

        let exitCode = AgentMeterLocalAutomationCommand.executeIfRequested(
            arguments: [
                "AgentMeter",
                "--agentmeter-launch-simulator-pairing",
                "653DB19C-D9A5-4F3A-91D5-DEF98DBC8CAE",
                "com.zain.agentmeter.ios.dev",
            ],
            environment: ["AGENTMETER_ENABLE_LOCAL_AUTOMATION": "1"],
            portProvider: { 54042 },
            pairingProvider: { _ in payload },
            openURL: { _, _ in
                Issue.record("openURL must not be called for launch pairing")
                return 1
            },
            launchApp: { simulatorID, bundleID, encoded in
                launched = (simulatorID, bundleID, encoded)
                return 0
            },
            checkBridgeAuth: { _ in
                Issue.record("checkBridgeAuth must not be called for launch pairing")
                return 1
            })

        #expect(exitCode == 0)
        #expect(launched?.simulatorID == "653DB19C-D9A5-4F3A-91D5-DEF98DBC8CAE")
        #expect(launched?.bundleID == "com.zain.agentmeter.ios.dev")
        let encoded = try #require(launched?.encoded)
        let data = try #require(Data(base64Encoded: encoded))
        let decoded = try JSONDecoder().decode(
            AgentMeterLocalAutomationCommand.SimulatorPairingPayload.self,
            from: data)
        #expect(decoded == payload)
    }

    @Test
    func `local automation fails safely when bridge port is missing`() {
        let exitCode = AgentMeterLocalAutomationCommand.executeIfRequested(
            arguments: ["AgentMeter", "--agentmeter-open-simulator-pairing", "booted"],
            environment: ["AGENTMETER_ENABLE_LOCAL_AUTOMATION": "1"],
            portProvider: { nil },
            pairingProvider: { _ in nil },
            openURL: { _, _ in 0 },
            launchApp: { _, _, _ in 0 },
            checkBridgeAuth: { _ in 0 })

        #expect(exitCode == 65)
    }

    @Test
    func `local automation probes bridge auth without creating simulator payload`() {
        var probedPort: UInt16?
        let exitCode = AgentMeterLocalAutomationCommand.executeIfRequested(
            arguments: ["AgentMeter", "--agentmeter-check-bridge-auth"],
            environment: ["AGENTMETER_ENABLE_LOCAL_AUTOMATION": "1"],
            portProvider: { 54042 },
            pairingProvider: { _ in
                Issue.record("pairingProvider must not be called for auth probe")
                return nil
            },
            openURL: { _, _ in 1 },
            launchApp: { _, _, _ in 1 },
            checkBridgeAuth: { port in
                probedPort = port
                return 0
            })

        #expect(exitCode == 0)
        #expect(probedPort == 54042)
    }
}

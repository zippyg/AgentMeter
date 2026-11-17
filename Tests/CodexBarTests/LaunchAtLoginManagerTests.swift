import ServiceManagement
import Testing
@testable import AgentMeter

@MainActor
struct LaunchAtLoginManagerTests {
    @Test
    func `set enabled skips registration when service is already enabled`() {
        var registerCalls = 0
        var unregisterCalls = 0

        LaunchAtLoginManager.setEnabled(
            true,
            status: { .enabled },
            register: { registerCalls += 1 },
            unregister: { unregisterCalls += 1 })

        #expect(registerCalls == 0)
        #expect(unregisterCalls == 0)
    }

    @Test
    func `set enabled registers when service is not registered`() {
        var registerCalls = 0
        var unregisterCalls = 0

        LaunchAtLoginManager.setEnabled(
            true,
            status: { .notRegistered },
            register: { registerCalls += 1 },
            unregister: { unregisterCalls += 1 })

        #expect(registerCalls == 1)
        #expect(unregisterCalls == 0)
    }

    @Test
    func `set enabled skips registration when service requires approval`() {
        var registerCalls = 0
        var unregisterCalls = 0

        LaunchAtLoginManager.setEnabled(
            true,
            status: { .requiresApproval },
            register: { registerCalls += 1 },
            unregister: { unregisterCalls += 1 })

        #expect(registerCalls == 0)
        #expect(unregisterCalls == 0)
    }

    @Test
    func `set enabled registers when service is not found`() {
        var registerCalls = 0
        var unregisterCalls = 0

        LaunchAtLoginManager.setEnabled(
            true,
            status: { .notFound },
            register: { registerCalls += 1 },
            unregister: { unregisterCalls += 1 })

        #expect(registerCalls == 1)
        #expect(unregisterCalls == 0)
    }

    @Test
    func `set disabled unregisters when service is enabled`() {
        var registerCalls = 0
        var unregisterCalls = 0

        LaunchAtLoginManager.setEnabled(
            false,
            status: { .enabled },
            register: { registerCalls += 1 },
            unregister: { unregisterCalls += 1 })

        #expect(registerCalls == 0)
        #expect(unregisterCalls == 1)
    }

    @Test
    func `set disabled unregisters when service requires approval`() {
        var registerCalls = 0
        var unregisterCalls = 0

        LaunchAtLoginManager.setEnabled(
            false,
            status: { .requiresApproval },
            register: { registerCalls += 1 },
            unregister: { unregisterCalls += 1 })

        #expect(registerCalls == 0)
        #expect(unregisterCalls == 1)
    }

    @Test
    func `set disabled skips unregister when service is not registered`() {
        var registerCalls = 0
        var unregisterCalls = 0

        LaunchAtLoginManager.setEnabled(
            false,
            status: { .notRegistered },
            register: { registerCalls += 1 },
            unregister: { unregisterCalls += 1 })

        #expect(registerCalls == 0)
        #expect(unregisterCalls == 0)
    }

    @Test
    func `set disabled skips unregister when service is not found`() {
        var registerCalls = 0
        var unregisterCalls = 0

        LaunchAtLoginManager.setEnabled(
            false,
            status: { .notFound },
            register: { registerCalls += 1 },
            unregister: { unregisterCalls += 1 })

        #expect(registerCalls == 0)
        #expect(unregisterCalls == 0)
    }

    @Test
    func `only an installed app outside QA may register at login`() {
        #expect(LaunchAtLoginManager.mayRegister(bundlePath: "/Applications/AgentMeter.app", environment: [:]))
        #expect(!LaunchAtLoginManager.mayRegister(bundlePath: "/Applications/AgentMeter.app",
                                                  environment: ["AGENTMETER_QA_ALLOW": "1"]))
        for path in ["/Users/invented/repo/.build/arm64-apple-macosx/debug",
                     "/Users/invented/repo/.agentmeter-artifacts/AgentMeter-release.app",
                     "/Users/invented/Applications/AgentMeter.app"] {
            #expect(!LaunchAtLoginManager.mayRegister(bundlePath: path, environment: [:]))
        }
    }
}

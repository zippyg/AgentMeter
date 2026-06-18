import Foundation
import Testing
@testable import AgentMeter

struct InstallOriginTests {
    @Test
    func `detects homebrew caskroom`() {
        #expect(
            InstallOrigin
                .isHomebrewCask(
                    appBundleURL: URL(fileURLWithPath: "/opt/homebrew/Caskroom/agentmeter/1.0.0/AgentMeter.app")))
        #expect(
            InstallOrigin
                .isHomebrewCask(
                    appBundleURL: URL(fileURLWithPath: "/usr/local/Caskroom/agentmeter/1.0.0/AgentMeter.app")))
        #expect(!InstallOrigin.isHomebrewCask(appBundleURL: URL(fileURLWithPath: "/Applications/AgentMeter.app")))
    }
}

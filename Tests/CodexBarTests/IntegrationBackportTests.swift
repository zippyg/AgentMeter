import Foundation
import Testing
@testable import CodexBarCore

struct IntegrationBackportTests {
    @Test func oversizedSubprocessTimeoutDoesNotTrap() async throws {
        let result = try await SubprocessRunner.run(
            binary: "/usr/bin/true",
            arguments: [],
            environment: [:],
            timeout: Double.greatestFiniteMagnitude,
            label: "timeout-overflow-test")
        #expect(result.stdout.isEmpty)
    }

    @Test func timeoutIncludesPipesInheritedByExitedProcessChildren() async throws {
        let start = Date()
        do {
            _ = try await SubprocessRunner.run(
                binary: "/usr/bin/python3",
                arguments: ["-c", "import subprocess; subprocess.Popen(['/bin/sleep', '10'])"],
                environment: [:],
                timeout: 0.3,
                label: "inherited-pipe-timeout")
            Issue.record("Expected timeout while draining inherited pipe")
        } catch let error as SubprocessRunnerError {
            guard case .timedOut = error else { Issue.record("Unexpected error"); return }
        }
        // The orphaned child lives 10s. Returning well inside that proves the runner did not wait
        // on the pipe it inherited. The bound is deliberately loose: asserting a time close to the
        // child's lifetime made this fail under full-suite load while passing in isolation.
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func bothClaudeProbePathsDisableRemoteControl() {
        #expect(ClaudeCLISession.probeSettingsArguments == ["--settings", #"{"remoteControlAtStartup":false}"#])
        #expect(ClaudeCLISession.probeArguments.contains("--strict-mcp-config"))
        #expect(ClaudeCLISession.probeArguments.suffix(2) == ClaudeCLISession.probeSettingsArguments[...])
    }

    @Test(arguments: [401, 403])
    func codexPermissionErrorsRemainDistinct(status: Int) async throws {
        let configuration = CodexAuthenticatedHTTPTransport.makeConfiguration()
        configuration.protocolClasses = [PermissionResponseProtocol.self]
        let transport = CodexAuthenticatedHTTPTransport.makeClient(configuration: configuration)
        do {
            _ = try await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
                try await CodexOAuthUsageFetcher.fetchUsage(
                    accessToken: "synthetic", accountId: String(status), env: ["CODEX_HOME": "/tmp/missing-test-home"])
            }
            Issue.record("Expected HTTP error")
        } catch let error as CodexOAuthFetchError {
            switch error {
            case .unauthorized: #expect(status == 401)
            case let .serverError(code, _): #expect(status == 403 && code == 403)
            default: Issue.record("Unexpected error type")
            }
        }
    }
}

private final class PermissionResponseProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let status = Int(self.request.value(forHTTPHeaderField: "ChatGPT-Account-Id") ?? "") ?? 500
        guard let url = self.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else { return }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data("{}".utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

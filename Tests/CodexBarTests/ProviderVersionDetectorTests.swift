import XCTest
@testable import CodexBarCore

final class ProviderVersionDetectorTests: XCTestCase {
    func test_run_returnsFirstLineForSuccessfulCommand() {
        let version = ProviderVersionDetector.run(
            path: "/bin/sh",
            args: ["-c", "printf 'gemini 1.2.3\\nextra\\n'"],
            timeout: 1.0)

        XCTAssertEqual(version, "gemini 1.2.3")
    }

    func test_run_returnsNilAfterTimeout() {
        let start = Date()
        let version = ProviderVersionDetector.run(
            path: "/bin/sh",
            args: ["-c", "sleep 5"],
            timeout: 0.1)
        let duration = Date().timeIntervalSince(start)

        XCTAssertNil(version)
        XCTAssertLessThan(duration, 2.0)
    }
}

extension ProviderVersionDetectorTests {
    func test_claudeVersion_backgroundProbesAreThrottledIncludingFailures() {
        let path = "/test/claude-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var probes = 0
        ProviderInteractionContext.$current.withValue(.background) {
            XCTAssertNil(ProviderVersionDetector.detectClaudeVersion(path: path, now: now) {
                probes += 1
                return nil
            })
            XCTAssertNil(ProviderVersionDetector.detectClaudeVersion(path: path, now: now.addingTimeInterval(299)) {
                probes += 1
                return "unexpected"
            })
            XCTAssertEqual(probes, 1)
            XCTAssertEqual(ProviderVersionDetector.detectClaudeVersion(path: path, now: now.addingTimeInterval(300)) {
                probes += 1
                return "2.1.70"
            }, "2.1.70")
            XCTAssertEqual(probes, 2)
        }
    }

    func test_claudeVersion_userActionBypassesBackgroundThrottle() {
        let path = "/test/claude-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = ProviderVersionDetector.detectClaudeVersion(path: path, now: now) { nil }
        let version = ProviderInteractionContext.$current.withValue(.userInitiated) {
            ProviderVersionDetector.detectClaudeVersion(path: path, now: now) { "2.1.70" }
        }
        XCTAssertEqual(version, "2.1.70")
        XCTAssertEqual(ProviderVersionDetector.detectClaudeVersion(path: path, now: now) { "unexpected" }, "2.1.70")
    }
}

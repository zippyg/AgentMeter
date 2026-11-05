import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeDirectUsageFallbackTests {
    private final class InvocationLog: @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()

        init(url: URL) {
            self.url = url
        }

        func contents() -> String {
            self.lock.withLock {
                (try? String(contentsOf: self.url, encoding: .utf8)) ?? ""
            }
        }
    }

    @Test
    func `cli source returns subscription snapshot when direct usage has no quota data`() async throws {
        let cliLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-direct-fallback-log-\(UUID().uuidString).txt")
        let log = InvocationLog(url: cliLogURL)
        let fakeCLI = try Self.makeDirectFallbackClaudeCLI(logURL: cliLogURL)
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [
                "CLAUDE_CLI_PATH": fakeCLI.path,
                ClaudeOAuthCredentialsStore.environmentTokenKey: "oauth-token",
                ClaudeOAuthCredentialsStore.environmentScopesKey: "user:profile",
                "ANTHROPIC_ADMIN_KEY": "admin-token",
            ],
            dataSource: .cli)

        try await ClaudeCLISession.withIsolatedSessionForTesting {
            try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting(fakeCLI.path) {
                let snapshot = try await fetcher.loadLatestUsage(model: "sonnet")
                #expect(snapshot.primaryWindowKind == .spendLimit)
                #expect(snapshot.primary.usedPercent == 0)
                #expect(snapshot.secondary == nil)
                #expect(snapshot.opus == nil)
                #expect(snapshot.loginMethod == "Claude subscription")
                #expect(snapshot.rawText?.contains("subscription") == true)

                let extra = try #require(snapshot.extraRateWindows.first)
                #expect(extra.id == "claude-subscription")
                #expect(extra.title == "Subscription")
                #expect(extra.usageKnown == false)
            }
        }

        let invocations = log.contents()
        #expect(invocations.contains("pty-usage"))
        #expect(invocations.contains("direct-usage"))
        #expect(invocations.contains("startup-settings"))
        #expect(!invocations.contains("pty-secret-env"))
        #expect(!invocations.contains("direct-secret-env"))
    }

    @Test
    func `direct usage timeout keeps original pty failure`() async throws {
        let cliLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-direct-timeout-log-\(UUID().uuidString).txt")
        let log = InvocationLog(url: cliLogURL)
        let fakeCLI = try Self.makeDirectTimeoutClaudeCLI(logURL: cliLogURL)
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: ["CLAUDE_CLI_PATH": fakeCLI.path],
            dataSource: .cli)

        await ClaudeCLISession.withIsolatedSessionForTesting {
            await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting(fakeCLI.path) {
                do {
                    _ = try await fetcher.loadLatestUsage(model: "sonnet")
                    #expect(Bool(false), "PTY failure should still surface")
                } catch let ClaudeStatusProbeError.parseFailed(message) {
                    #expect(message.lowercased().contains("could not load usage data"))
                } catch {
                    #expect(Bool(false), "Unexpected error: \(error)")
                }
            }
        }

        let invocations = log.contents()
        #expect(invocations.contains("pty-usage"))
        #expect(invocations.contains("direct-usage"))
        #expect(invocations.contains("startup-settings"))
    }

    @Test
    func `cli source merges fresh scoped status line cache windows`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeDirectUsageFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("usage-cache.json")
        FileManager.default.createFile(
            atPath: cache.path,
            contents: Data("""
            {
              "five_hour": {"utilization": 86, "resets_at": "2026-07-02T10:50:00.637776+00:00"},
              "seven_day": {"utilization": 12, "resets_at": "2026-07-06T21:00:00.637799+00:00"},
              "limits": [
                {"group": "session", "percent": 86, "scope": null},
                {"group": "weekly", "percent": 12, "scope": null},
                {
                  "group": "weekly",
                  "percent": 17,
                  "resets_at": "2099-07-06T20:59:59.638573+00:00",
                  "scope": {"model": {"display_name": "Fable"}}
                }
              ]
            }
            """.utf8))
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cache.path)

        let cliLogURL = root.appendingPathComponent("claude-cli.log")
        let fakeCLI = try Self.makeSuccessfulClaudeCLI(logURL: cliLogURL)
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [
                "CLAUDE_CLI_PATH": fakeCLI.path,
                ClaudeStatusLineUsageCache.overridePathEnvironmentKey: cache.path,
            ],
            dataSource: .cli)

        try await ClaudeCLISession.withIsolatedSessionForTesting {
            try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting(fakeCLI.path) {
                let snapshot = try await fetcher.loadLatestUsage(model: "sonnet")
                #expect(snapshot.primary.usedPercent == 86)
                #expect(snapshot.secondary?.usedPercent == 12)
                let fable = try #require(snapshot.extraRateWindows.first(where: { $0.id == "claude-fable" }))
                #expect(fable.title == "Fable")
                #expect(fable.window.usedPercent == 17)

                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(-(ClaudeStatusLineUsageCache.maxAge + 60))],
                    ofItemAtPath: cache.path)
                let snapshotWithStaleCache = try await fetcher.loadLatestUsage(model: "sonnet")
                #expect(snapshotWithStaleCache.extraRateWindows.contains { $0.id == "claude-fable" } == false)
            }
        }
    }

    private static func makeDirectFallbackClaudeCLI(logURL: URL) throws -> URL {
        try self.makeClaudeCLI(name: "claude-direct-fallback", logURL: logURL, scriptBody: """
        if [ "$1" = "/usage" ]; then
          printf 'direct-usage\\n' >> "$LOG_FILE"
          if [ -n "$CODEXBAR_CLAUDE_OAUTH_TOKEN" ] ||
             [ -n "$CODEXBAR_CLAUDE_OAUTH_SCOPES" ] ||
             [ -n "$ANTHROPIC_ADMIN_KEY" ]; then
            printf 'direct-secret-env\\n' >> "$LOG_FILE"
          fi
          printf '%s\\n' 'You are currently using your subscription to power your Claude Code usage'
          exit 0
        fi
        while IFS= read -r line; do
          case "$line" in
            *"/usage"*)
              printf 'pty-usage\\n' >> "$LOG_FILE"
              if [ -n "$CODEXBAR_CLAUDE_OAUTH_TOKEN" ] ||
                 [ -n "$CODEXBAR_CLAUDE_OAUTH_SCOPES" ] ||
                 [ -n "$ANTHROPIC_ADMIN_KEY" ]; then
                printf 'pty-secret-env\\n' >> "$LOG_FILE"
              fi
              printf '%s\\n' 'You are currently using your subscription to power your Claude Code usage'
              ;;
            *"/status"*)
              printf 'pty-status\\n' >> "$LOG_FILE"
              printf '%s\\n' 'Account: subscription@example.com'
              ;;
          esac
        done
        """)
    }

    private static func makeDirectTimeoutClaudeCLI(logURL: URL) throws -> URL {
        try self.makeClaudeCLI(name: "claude-direct-timeout", logURL: logURL, scriptBody: """
        if [ "$1" = "/usage" ]; then
          printf 'direct-usage\\n' >> "$LOG_FILE"
          sleep 30
          exit 0
        fi
        while IFS= read -r line; do
          case "$line" in
            *"/usage"*)
              printf 'pty-usage\\n' >> "$LOG_FILE"
              printf '%s\\n' 'Failed to load usage data'
              ;;
          esac
        done
        """)
    }

    private static func makeSuccessfulClaudeCLI(logURL: URL) throws -> URL {
        let usageOutput = """
        Settings: Usage
        Current session
        86% used
        Resets Jul 2 at 11:50am (Europe/London)
        Current week (all models)
        12% used
        Resets Jul 6 at 10pm (Europe/London)
        """
        return try self.makeClaudeCLI(name: "claude-successful-usage", logURL: logURL, scriptBody: """
        if [ "$1" = "/usage" ]; then
          printf 'direct-usage\\n' >> "$LOG_FILE"
          printf '%s\\n' '\(usageOutput)'
          exit 0
        fi
        while IFS= read -r line; do
          case "$line" in
            *"/usage"*)
              printf 'pty-usage\\n' >> "$LOG_FILE"
              printf '%s\\n' '\(usageOutput)'
              ;;
            *"/status"*)
              printf 'pty-status\\n' >> "$LOG_FILE"
              printf '%s\\n' 'Login method: Claude Max'
              ;;
          esac
        done
        """)
    }

    private static func makeClaudeCLI(name: String, logURL: URL, scriptBody: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        LOG_FILE='\(logURL.path)'
        settings_seen=0
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --settings)
              [ "$2" = '{"remoteControlAtStartup":false}' ] || exit 64
              settings_seen=1
              shift 2
              ;;
            /usage) break ;;
            *) shift ;;
          esac
        done
        [ "$settings_seen" = 1 ] || exit 65
        printf 'startup-settings\\n' >> "$LOG_FILE"
        \(scriptBody)
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}

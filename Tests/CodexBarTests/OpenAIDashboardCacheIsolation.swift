import CodexBarCore
import Foundation
import Testing

struct OpenAIDashboardCacheIsolation: TestTrait, SuiteTrait, TestScoping {
    let isRecursive = true

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await OpenAIDashboardCacheStore.$cacheURLOverride.withValue(root.appendingPathComponent("dashboard.json")) {
            try await function()
        }
    }
}

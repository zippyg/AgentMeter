import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct AgentMeterSnapshotTests {
    @Test
    func `widget snapshot converts to agentmeter summary`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nextRefreshAt = now.addingTimeInterval(300)
        let producer = AgentMeterSnapshotProducer(
            bundleIdentifier: "com.zain.agentmeter.tests",
            displayName: "AgentMeter Tests",
            version: "1",
            build: "2")
        let codexEntry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: now,
            primary: RateWindow(
                usedPercent: 42,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: "resets in 1h"),
            secondary: RateWindow(
                usedPercent: 12,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(86400),
                resetDescription: "resets tomorrow"),
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "codeReview",
                    title: "Code review",
                    percentLeft: 75),
            ],
            creditsRemaining: 18.5,
            codeReviewRemainingPercent: 75,
            tokenUsage: WidgetSnapshot.TokenUsageSummary(
                sessionCostUSD: 0.12,
                sessionTokens: 1200,
                last30DaysCostUSD: 3.40,
                last30DaysTokens: 34000),
            dailyUsage: [])
        let widgetSnapshot = WidgetSnapshot(entries: [codexEntry], generatedAt: now)

        let snapshot = AgentMeterSnapshot(
            widgetSnapshot: widgetSnapshot,
            staleInterval: 60,
            snapshotSequence: 42,
            producer: producer,
            nextRefreshAt: nextRefreshAt)

        #expect(snapshot.schemaVersion == 2)
        #expect(snapshot.snapshotSequence == 42)
        #expect(snapshot.producer == producer)
        let provider = try #require(snapshot.providers.first)
        #expect(provider.id == "codex")
        #expect(provider.displayName == "Codex")
        #expect(provider.source.confidence == .derived)
        #expect(provider.status == .ok)
        #expect(provider.staleAfter == now.addingTimeInterval(60))
        #expect(provider.nextRefreshAt == nextRefreshAt)
        #expect(provider.windows.map(\.id) == ["session", "weekly", "codeReview"])
        #expect(provider.windows[0].remainingPercent == 58)
        #expect(provider.windows[1].remainingPercent == 88)
        #expect(provider.windows[2].remainingPercent == 75)
        #expect(provider.creditsRemaining == 18.5)
        #expect(provider.codeReviewRemainingPercent == 75)
        #expect(provider.tokenUsage?.sessionTokens == 1200)
    }

    @Test
    func `legacy summary without v2 fields still decodes`() throws {
        let json = """
        {
          "generatedAt": "2027-01-15T08:00:00Z",
          "providers": [
            {
              "id": "claude",
              "displayName": "Claude",
              "windows": [],
              "source": {
                "confidence": "local",
                "label": "fixture"
              },
              "status": "ok",
              "updatedAt": "2027-01-15T08:00:00Z"
            }
          ]
        }
        """

        let snapshot = try AgentMeterSnapshotStore.decoder.decode(
            AgentMeterSnapshot.self,
            from: Data(json.utf8))

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.snapshotSequence == 0)
        #expect(snapshot.producer == nil)
        #expect(snapshot.providers.first?.nextRefreshAt == nil)
        #expect(snapshot.providers.first?.lastError == nil)
    }

    @Test
    func `bridge pairing url can carry direct endpoint fallback`() throws {
        let pairingToken = ["agent", "meter", "pairing", "test"].joined(separator: "-")
        let url = try #require(AgentMeterBridgeTokenStore.pairingURL(
            serviceName: "AgentMeter Test Mac",
            token: pairingToken,
            directHost: "192.168.0.10",
            directPort: 62974))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        #expect(url.scheme == "agentmeter")
        #expect(url.host == "pair")
        #expect(value("service") == "AgentMeter Test Mac")
        #expect(value("type") == "_agentmeter._tcp")
        #expect(value("token") == pairingToken)
        #expect(value("host") == "192.168.0.10")
        #expect(value("port") == "62974")
    }

    @Test
    func `transient empty summary preserves previous providers as stale`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = AgentMeterSnapshot(
            snapshotSequence: 4,
            generatedAt: now.addingTimeInterval(-60),
            providers: [
                AgentMeterProviderSnapshot(
                    id: "codex",
                    displayName: "Codex",
                    windows: [
                        AgentMeterUsageWindow(
                            id: "session",
                            title: "Session",
                            usedPercent: 20,
                            remainingPercent: 80,
                            resetsAt: nil,
                            resetDescription: nil,
                            windowMinutes: 300),
                    ],
                    source: AgentMeterSourceDescriptor(confidence: .local, label: "fixture"),
                    status: .ok,
                    updatedAt: now.addingTimeInterval(-60),
                    staleAfter: now.addingTimeInterval(300)),
            ])
        let current = AgentMeterSnapshot(
            snapshotSequence: 5,
            generatedAt: now,
            providers: [])

        let repaired = current.preservingPreviousProvidersOnTransientEmpty(
            previous: previous,
            nextRefreshAt: now.addingTimeInterval(60),
            now: now)

        #expect(repaired.snapshotSequence == 5)
        #expect(repaired.providers.map(\.id) == ["codex"])
        #expect(repaired.providers.first?.status == .stale)
        #expect(repaired.providers.first?.staleAfter == now)
        #expect(repaired.providers.first?.nextRefreshAt == now.addingTimeInterval(60))
        #expect(repaired.providers.first?.lastError?.contains("No fresh provider snapshots") == true)
    }

    @Test
    func `widget snapshot converts to phone projection`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let codexEntry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: now,
            primary: RateWindow(
                usedPercent: 42,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: "resets in 1h"),
            secondary: RateWindow(
                usedPercent: 12,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(86400),
                resetDescription: "resets tomorrow"),
            tertiary: nil,
            usageRows: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: WidgetSnapshot.TokenUsageSummary(
                sessionCostUSD: 0.12,
                sessionTokens: 1200,
                last30DaysCostUSD: 3.40,
                last30DaysTokens: 34000),
            dailyUsage: [
                WidgetSnapshot.DailyUsagePoint(dayKey: "2027-01-14", totalTokens: 1200, costUSD: 0.12),
            ])
        let claudeEntry = WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: now,
            primary: RateWindow(
                usedPercent: 70,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            usageRows: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let geminiEntry = WidgetSnapshot.ProviderEntry(
            provider: .gemini,
            updatedAt: now,
            primary: RateWindow(
                usedPercent: 5,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            usageRows: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let widgetSnapshot = WidgetSnapshot(entries: [geminiEntry, codexEntry, claudeEntry], generatedAt: now)

        let phoneSnapshot = AgentMeterPhoneSnapshot(widgetSnapshot: widgetSnapshot, staleInterval: 60)

        #expect(phoneSnapshot.generatedAt == now)
        #expect(phoneSnapshot.providers.map(\.id) == ["codex", "claude"])
        let codex = try #require(phoneSnapshot.providers.first { $0.id == "codex" })
        #expect(codex.displayName == "Codex")
        #expect(codex.windows.map(\.id) == ["session", "weekly"])
        #expect(codex.windows.first?.usedPercent == 42)
        #expect(codex.windows.first?.remainingPercent == 58)
        #expect(codex.tokenUsage?.sessionTokens == 1200)
        #expect(codex.dailyUsage.first?.dayKey == "2027-01-14")
        #expect(codex.source.confidence == .derived)
        #expect(codex.status == .ok)
        #expect(codex.staleAfter == now.addingTimeInterval(60))

        let data = try AgentMeterPhoneSnapshotStore.encoder.encode(phoneSnapshot)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("apiKey"))
        #expect(!json.contains("cookieHeader"))
        #expect(!json.contains("Bearer"))
        let decoded = try AgentMeterPhoneSnapshotStore.decoder.decode(AgentMeterPhoneSnapshot.self, from: data)
        #expect(decoded == phoneSnapshot)
    }

    @Test
    func `summary store round trips without secret fields`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-summary-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent(AgentMeterSnapshotStore.filename)
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = AgentMeterSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1),
            providers: [
                AgentMeterProviderSnapshot(
                    id: "claude",
                    displayName: "Claude",
                    windows: [
                        AgentMeterUsageWindow(
                            id: "session",
                            title: "Session",
                            usedPercent: 10,
                            remainingPercent: 90,
                            resetsAt: nil,
                            resetDescription: nil,
                            windowMinutes: 300),
                    ],
                    source: AgentMeterSourceDescriptor(confidence: .local, label: "fixture"),
                    status: .ok,
                    updatedAt: Date(timeIntervalSince1970: 1),
                    staleAfter: Date(timeIntervalSince1970: 901)),
            ])

        try AgentMeterSnapshotStore.save(snapshot, fileURL: fileURL, postNotification: { _, _ in })
        let data = try Data(contentsOf: fileURL)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("apiKey"))
        #expect(!json.contains("cookieHeader"))
        #expect(!json.contains("Bearer"))
        #expect(!AgentMeterSnapshotSecurity.containsSensitiveMaterial(data))
        #expect(AgentMeterSnapshotStore.load(fileURL: fileURL) == snapshot)
    }

    @Test
    func `summary notification payload is sanitized and versioned`() {
        let fileURL = URL(fileURLWithPath: "/tmp/agentmeter-summary.json")
        let snapshot = AgentMeterSnapshot(
            snapshotSequence: 42,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            providers: [])

        let payload = AgentMeterSnapshotNotification.userInfo(fileURL: fileURL, snapshot: snapshot)

        #expect(AgentMeterSnapshotNotification.name == "com.zain.agentmeter.snapshot.updated")
        #expect(payload["path"] as? String == "/tmp/agentmeter-summary.json")
        #expect(payload["schemaVersion"] as? Int == 2)
        #expect(payload["snapshotSequence"] as? Int == 42)
        #expect((payload["generatedAt"] as? String)?.isEmpty == false)
        #expect(!String(describing: payload).localizedCaseInsensitiveContains("token"))
        #expect(!String(describing: payload).localizedCaseInsensitiveContains("cookie"))
    }

    @Test
    func `summary store refuses obvious auth material`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-summary-secret-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent(AgentMeterSnapshotStore.filename)
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = AgentMeterSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1),
            providers: [
                AgentMeterProviderSnapshot(
                    id: "bad",
                    displayName: "Bad",
                    windows: [],
                    source: AgentMeterSourceDescriptor(confidence: .unknown, label: "bearer test"),
                    status: .error,
                    updatedAt: Date(timeIntervalSince1970: 1),
                    staleAfter: nil,
                    lastError: "Bearer token leaked"),
            ])

        #expect(throws: AgentMeterSnapshotStoreError.sensitiveMaterialDetected) {
            try AgentMeterSnapshotStore.save(snapshot, fileURL: fileURL, postNotification: { _, _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test
    func `phone snapshot store round trips with private permissions`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-phone-summary-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent(AgentMeterPhoneSnapshotStore.filename)
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = AgentMeterPhoneSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1),
            providers: [
                AgentMeterPhoneProvider(
                    id: "codex",
                    displayName: "Codex",
                    windows: [
                        AgentMeterPhoneUsageWindow(
                            id: "session",
                            title: "Session",
                            usedPercent: 10,
                            remainingPercent: 90,
                            resetsAt: nil,
                            resetDescription: nil,
                            windowMinutes: 300),
                    ],
                    source: AgentMeterPhoneSource(confidence: .local, label: "fixture"),
                    status: .ok,
                    updatedAt: Date(timeIntervalSince1970: 1),
                    staleAfter: Date(timeIntervalSince1970: 901)),
            ])

        try AgentMeterPhoneSnapshotStore.save(snapshot, fileURL: fileURL)
        let data = try Data(contentsOf: fileURL)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("apiKey"))
        #expect(!json.contains("cookieHeader"))
        #expect(!json.contains("Bearer"))
        #expect(AgentMeterPhoneSnapshotStore.load(fileURL: fileURL) == snapshot)

        #if os(macOS) || os(Linux)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #endif
    }

    @Test
    func `phone snapshot exporter copies sanitized snapshot with private permissions`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-phone-export-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = directory.appendingPathComponent("source-\(AgentMeterPhoneSnapshotStore.filename)")
        let destinationURL = directory.appendingPathComponent(AgentMeterPhoneSnapshotStore.filename)
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = AgentMeterPhoneSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1),
            providers: [
                AgentMeterPhoneProvider(
                    id: "claude",
                    displayName: "Claude",
                    windows: [
                        AgentMeterPhoneUsageWindow(
                            id: "session",
                            title: "Session",
                            usedPercent: 20,
                            remainingPercent: 80,
                            resetsAt: nil,
                            resetDescription: nil,
                            windowMinutes: 300),
                    ],
                    source: AgentMeterPhoneSource(confidence: .local, label: "fixture"),
                    status: .ok,
                    updatedAt: Date(timeIntervalSince1970: 1),
                    staleAfter: Date(timeIntervalSince1970: 901)),
            ])
        try AgentMeterPhoneSnapshotStore.save(snapshot, fileURL: sourceURL)

        let exportedURL = try AgentMeterPhoneSnapshotExporter.export(
            sourceURL: sourceURL,
            destinationURL: destinationURL)

        #expect(exportedURL == destinationURL)
        #expect(AgentMeterPhoneSnapshotStore.load(fileURL: destinationURL) == snapshot)
        let data = try Data(contentsOf: destinationURL)
        #expect(!AgentMeterPhoneSnapshotStore.containsSensitiveMaterial(data))

        #if os(macOS) || os(Linux)
        let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #endif
    }

    @Test
    func `phone snapshot exporter refuses obvious auth material`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-phone-export-secret-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = directory.appendingPathComponent("bad-\(AgentMeterPhoneSnapshotStore.filename)")
        let destinationURL = directory.appendingPathComponent(AgentMeterPhoneSnapshotStore.filename)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"providers":[],"access_token":"test"}"#.utf8).write(to: sourceURL)

        #expect(throws: AgentMeterPhoneSnapshotExportError.sensitiveMaterialDetected) {
            try AgentMeterPhoneSnapshotExporter.export(sourceURL: sourceURL, destinationURL: destinationURL)
        }
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test
    func `provider config can carry keychain references without inline secrets`() throws {
        let reference = AgentMeterCredentialReference(account: "openai.apiKey", label: "OpenAI API key")
        try AgentMeterKeychainCredentialStore().store("sk-agentmeter-test", for: reference)
        defer { try? AgentMeterKeychainCredentialStore().delete(reference: reference) }

        let config = ProviderConfig(
            id: .openai,
            source: .api,
            credentialReferences: ProviderCredentialReferences(apiKey: reference))

        #expect(config.containsInlineSecretMaterial == false)
        #expect(config.credentialReferences?.apiKey == reference)
        #expect(config.sanitizedAPIKey == "sk-agentmeter-test")

        let data = try JSONEncoder().encode(config)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(AgentMeterKeychainCredentialStore.serviceName))
        #expect(!json.contains("sk-"))
    }

    @Test
    func `config secret migrator moves inline secrets to keychain references`() throws {
        let accountID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .claude,
                source: .web,
                apiKey: "sk-ant-admin-test",
                cookieHeader: "sessionKey=claude-test",
                tokenAccounts: ProviderTokenAccountData(
                    version: 1,
                    accounts: [
                        ProviderTokenAccount(
                            id: accountID,
                            label: "Primary",
                            token: "account-token-test",
                            addedAt: 0,
                            lastUsed: nil),
                    ],
                    activeIndex: 0)),
            ProviderConfig(
                id: .bedrock,
                source: .api,
                apiKey: "AKIA_TEST",
                secretKey: "aws-secret-test"),
        ])

        let result = AgentMeterConfigSecretMigrator.migrateInlineSecrets(in: config)

        #expect(result.failedSecretCount == 0)
        #expect(result.migratedSecretCount == 5)

        let claude = try #require(result.config.providerConfig(for: .claude))
        let bedrock = try #require(result.config.providerConfig(for: .bedrock))
        let account = try #require(claude.tokenAccounts?.accounts.first)

        #expect(claude.apiKey == nil)
        #expect(claude.cookieHeader == nil)
        #expect(account.containsInlineSecretMaterial == false)
        #expect(bedrock.apiKey == nil)
        #expect(bedrock.secretKey == nil)

        #expect(claude.sanitizedAPIKey == "sk-ant-admin-test")
        #expect(claude.sanitizedCookieHeader == "sessionKey=claude-test")
        #expect(account.token == "account-token-test")
        #expect(bedrock.sanitizedAPIKey == "AKIA_TEST")
        #expect(bedrock.sanitizedSecretKey == "aws-secret-test")

        let data = try JSONEncoder().encode(result.config)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("sk-ant-admin-test"))
        #expect(!json.contains("sessionKey=claude-test"))
        #expect(!json.contains("account-token-test"))
        #expect(!json.contains("AKIA_TEST"))
        #expect(!json.contains("aws-secret-test"))
        #expect(json.contains("credentialReferences"))
        #expect(json.contains("credentialReference"))
    }

    @Test
    func `keychain credential store uses agentmeter service`() throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let store = AgentMeterKeychainCredentialStore()
        let reference = AgentMeterCredentialReference(account: "claude.cookie")

        try store.store("secret-value", for: reference)
        #expect(try store.load(reference: reference) == "secret-value")
        try store.delete(reference: reference)
        #expect(try store.load(reference: reference) == nil)
    }

    @Test
    func `wrong keychain service is rejected before lookup`() throws {
        let store = AgentMeterKeychainCredentialStore()
        let reference = AgentMeterCredentialReference(service: "com.example.other", account: "codex.oauth")

        #expect(throws: AgentMeterCredentialStoreError.serviceMismatch(
            expected: AgentMeterKeychainCredentialStore.serviceName,
            actual: "com.example.other"))
        {
            try store.load(reference: reference)
        }
    }
}

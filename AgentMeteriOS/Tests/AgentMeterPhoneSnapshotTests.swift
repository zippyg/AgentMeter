import XCTest

final class AgentMeterPhoneSnapshotTests: XCTestCase {
    func test_sampleSnapshotContainsClaudeAndCodex() throws {
        let snapshot = AgentMeterSampleData.snapshot(now: Date(timeIntervalSince1970: 1_812_998_400))

        XCTAssertEqual(snapshot.providers.map(\.id), ["claude", "codex"])
        XCTAssertEqual(snapshot.claude?.displayName, "Claude")
        XCTAssertEqual(snapshot.codex?.displayName, "Codex")
        XCTAssertEqual(snapshot.claude?.primaryWindow?.usedPercent, 42)
        XCTAssertEqual(snapshot.codex?.weeklyWindow?.usedPercent, 51)
    }

    func test_sampleJSONRoundTripsWithoutSecrets() throws {
        let data = AgentMeterSampleData.jsonData
        let decoded = try JSONDecoder.agentMeter.decode(AgentMeterPhoneSnapshot.self, from: data)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(decoded.providers.count, 2)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("bearer"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("secret"))
    }

    func test_bridgeRequestBuilderKeepsSignatureHeaderIsolated() throws {
        let signature = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNO123"
        let request = AgentMeterBridgeHTTPRequestBuilder.snapshotRequest(
            timestamp: "1780000000",
            nonce: "abcDEF1234567890_abcDEF1234567890",
            signature: signature,
            deviceID: nil)
        let lines = request.components(separatedBy: "\r\n")
        let signatureLine = try XCTUnwrap(lines.first { $0.hasPrefix("X-AgentMeter-Bridge-Signature: ") })

        XCTAssertEqual(signatureLine, "X-AgentMeter-Bridge-Signature: \(signature)")
        XCTAssertTrue(lines.contains("Connection: close"))
        XCTAssertTrue(request.hasSuffix("\r\n\r\n"))
    }

    func test_securePairingInvitationDoesNotRequireTokenInURL() throws {
        let macKey = String(repeating: "A", count: 43)
        let url = try XCTUnwrap(URL(string: """
        agentmeter://pair?v=2&service=AgentMeter%20Test&type=_agentmeter._tcp&session=abcdefghijklmnopqrstuv&macKey=\(macKey)&host=127.0.0.1&port=54042
        """))
        let invitation = try XCTUnwrap(AgentMeterBridgePairingInvitation(url: url))

        XCTAssertEqual(invitation.serviceName, "AgentMeter Test")
        XCTAssertEqual(invitation.sessionID, "abcdefghijklmnopqrstuv")
        XCTAssertEqual(invitation.macPublicKey, macKey)
        XCTAssertEqual(invitation.directHost, "127.0.0.1")
        XCTAssertEqual(invitation.directPort, 54042)
        XCTAssertNil(AgentMeterBridgePairing(url: url))
    }

    func test_pairingFinishRequestDoesNotTransmitCodeOrToken() throws {
        let request = AgentMeterBridgeHTTPRequestBuilder.pairingFinishRequest(
            sessionID: "abcdefghijklmnopqrstuv",
            clientPublicKey: "client_public_key_value",
            proof: "proof_value")

        XCTAssertTrue(request.hasPrefix("GET /pair/finish?"))
        XCTAssertTrue(request.contains("session=abcdefghijklmnopqrstuv"))
        XCTAssertTrue(request.contains("clientKey=client_public_key_value"))
        XCTAssertTrue(request.contains("proof=proof_value"))
        XCTAssertFalse(request.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(request.localizedCaseInsensitiveContains("code"))
        XCTAssertTrue(request.hasSuffix("\r\n\r\n"))
    }

    func test_storeLoadsMacContractSnapshotAndFiltersToPrimaryProviders() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-ios-store-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent(AgentMeterPhoneSnapshotStore.filename)
        defer { try? FileManager.default.removeItem(at: directory) }

        let json = """
        {
          "generatedAt": "2026-06-14T17:12:00Z",
          "providers": [
            {
              "dailyUsage": [
                {
                  "costUSD": 1.25,
                  "dayKey": "2026-06-14",
                  "totalTokens": 123000
                }
              ],
              "displayName": "Gemini",
              "id": "gemini",
              "source": {
                "confidence": "private",
                "label": "Hidden fixture"
              },
              "status": "ok",
              "updatedAt": "2026-06-14T17:11:00Z",
              "windows": []
            },
            {
              "accountLabel": "Personal",
              "dailyUsage": [
                {
                  "costUSD": 2.16,
                  "dayKey": "2026-06-14",
                  "totalTokens": 252000
                }
              ],
              "displayName": "Codex",
              "id": "codex",
              "plan": "Plus",
              "source": {
                "confidence": "derived",
                "detail": "Local JSONL usage projection",
                "label": "Local snapshot"
              },
              "staleAfter": "2026-06-14T17:27:00Z",
              "status": "ok",
              "tokenUsage": {
                "currencyCode": "USD",
                "last30DaysCostUSD": 37.2,
                "last30DaysLabel": "30d",
                "last30DaysTokens": 4600000,
                "sessionCostUSD": 2.16,
                "sessionLabel": "Today",
                "sessionTokens": 252000
              },
              "updatedAt": "2026-06-14T17:11:00Z",
              "windows": [
                {
                  "id": "session",
                  "remainingPercent": 76,
                  "resetDescription": "3h",
                  "resetsAt": "2026-06-14T20:12:00Z",
                  "title": "Session",
                  "usedPercent": 24,
                  "windowMinutes": 300
                }
              ]
            },
            {
              "dailyUsage": [],
              "displayName": "Claude",
              "id": "claude",
              "source": {
                "confidence": "local",
                "label": "Local snapshot"
              },
              "status": "stale",
              "updatedAt": "2026-06-14T17:10:00Z",
              "windows": [
                {
                  "id": "session",
                  "remainingPercent": 58,
                  "title": "Session",
                  "usedPercent": 42,
                  "windowMinutes": 300
                }
              ]
            }
          ]
        }
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)

        let snapshot = try XCTUnwrap(try AgentMeterPhoneSnapshotStore.load(fileURL: fileURL))

        XCTAssertEqual(snapshot.providers.map(\.id), ["claude", "codex"])
        XCTAssertEqual(snapshot.codex?.tokenUsage?.sessionTokens, 252_000)
        XCTAssertEqual(snapshot.codex?.dailyUsage.first?.costUSD, 2.16)
        XCTAssertEqual(snapshot.claude?.primaryWindow?.usedPercent, 42)
    }

    func test_storeSavesPrimaryProjectionWithoutSecrets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-ios-save-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent(AgentMeterPhoneSnapshotStore.filename)
        defer { try? FileManager.default.removeItem(at: directory) }

        var snapshot = AgentMeterSampleData.snapshot(now: Date(timeIntervalSince1970: 1_812_998_400))
        snapshot.providers.append(AgentMeterPhoneProvider(
            id: "gemini",
            displayName: "Gemini",
            accountLabel: nil,
            plan: nil,
            windows: [],
            tokenUsage: nil,
            dailyUsage: [],
            source: AgentMeterPhoneSource(confidence: .local, label: "fixture"),
            status: .ok,
            updatedAt: snapshot.generatedAt,
            staleAfter: nil))

        try AgentMeterPhoneSnapshotStore.save(snapshot, fileURL: fileURL)

        let data = try Data(contentsOf: fileURL)
        let text = String(decoding: data, as: UTF8.self)
        let decoded = try JSONDecoder.agentMeter.decode(AgentMeterPhoneSnapshot.self, from: data)

        XCTAssertEqual(decoded.providers.map(\.id), ["claude", "codex"])
        XCTAssertFalse(text.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("bearer"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("secret"))
    }

    func test_storeRejectsSensitiveMaterialBeforeWriting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-ios-secret-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent(AgentMeterPhoneSnapshotStore.filename)
        defer { try? FileManager.default.removeItem(at: directory) }

        var snapshot = AgentMeterSampleData.snapshot(now: Date(timeIntervalSince1970: 1_812_998_400))
        snapshot.providers[0].source.detail = "Bearer token fixture"

        XCTAssertThrowsError(try AgentMeterPhoneSnapshotStore.save(snapshot, fileURL: fileURL)) { error in
            XCTAssertEqual(error as? AgentMeterPhoneSnapshotStoreError, .sensitiveMaterialDetected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func test_importSnapshotPersistsPrimaryProjection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-ios-import-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let importURL = directory.appendingPathComponent("snapshot.json")
        let fileURL = directory.appendingPathComponent(AgentMeterPhoneSnapshotStore.filename)
        defer { try? FileManager.default.removeItem(at: directory) }

        var snapshot = AgentMeterSampleData.snapshot(now: Date(timeIntervalSince1970: 1_812_998_400))
        snapshot.providers.append(AgentMeterPhoneProvider(
            id: "gemini",
            displayName: "Gemini",
            accountLabel: nil,
            plan: nil,
            windows: [],
            tokenUsage: nil,
            dailyUsage: [],
            source: AgentMeterPhoneSource(confidence: .local, label: "fixture"),
            status: .ok,
            updatedAt: snapshot.generatedAt,
            staleAfter: nil))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AgentMeterPhoneSnapshotStore.encoder.encode(snapshot).write(to: importURL)

        let imported = try AgentMeterPhoneSnapshotStore.importSnapshot(from: importURL, fileURL: fileURL)
        let persisted = try XCTUnwrap(try AgentMeterPhoneSnapshotStore.load(fileURL: fileURL))

        XCTAssertEqual(imported.providers.map(\.id), ["claude", "codex"])
        XCTAssertEqual(persisted.providers.map(\.id), ["claude", "codex"])
    }

    func test_importSnapshotRejectsSensitiveRawInputBeforeWriting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-ios-import-secret-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let importURL = directory.appendingPathComponent("snapshot.json")
        let fileURL = directory.appendingPathComponent(AgentMeterPhoneSnapshotStore.filename)
        defer { try? FileManager.default.removeItem(at: directory) }

        var object = try JSONSerialization.jsonObject(with: AgentMeterSampleData.jsonData) as? [String: Any]
        object?["apiKey"] = "fixture-value"
        let data = try JSONSerialization.data(withJSONObject: object as Any, options: [.prettyPrinted])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: importURL)

        XCTAssertThrowsError(try AgentMeterPhoneSnapshotStore.importSnapshot(from: importURL, fileURL: fileURL)) { error in
            XCTAssertEqual(error as? AgentMeterPhoneSnapshotStoreError, .sensitiveMaterialDetected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func test_loadOrSampleReturnsEmptySnapshotWhenCacheIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-ios-missing-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent(AgentMeterPhoneSnapshotStore.filename)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = AgentMeterPhoneSnapshotStore.loadOrSample(
            fileURL: fileURL,
            now: Date(timeIntervalSince1970: 1_812_998_400))

        XCTAssertEqual(result.source, .missing(fileURL))
        XCTAssertTrue(result.snapshot.providers.isEmpty)
        XCTAssertTrue(result.snapshot.isEmpty)
        XCTAssertFalse(result.snapshot.isSampleData)
        XCTAssertFalse(result.snapshot.isStale(reference: Date(timeIntervalSince1970: 1_812_998_400)))
    }

    func test_snapshotIsGloballyStaleOnlyWhenEveryProviderIsStale() throws {
        let now = Date(timeIntervalSince1970: 1_812_998_400)
        var snapshot = AgentMeterSampleData.snapshot(now: now)
        snapshot.providers[0].staleAfter = now.addingTimeInterval(-60)
        snapshot.providers[1].staleAfter = now.addingTimeInterval(60)

        XCTAssertFalse(snapshot.isStale(reference: now))
        XCTAssertTrue(snapshot.hasStaleProvider(reference: now))
        XCTAssertEqual(snapshot.providers[0].displayStatus(reference: now), .stale)
        XCTAssertEqual(snapshot.providers[1].displayStatus(reference: now), .ok)

        snapshot.providers[1].status = .stale

        XCTAssertTrue(snapshot.isStale(reference: now))
    }

    func test_usageRangesExposeKnownWindowsWithoutInventingLifetimeTotals() throws {
        let snapshot = AgentMeterSampleData.snapshot(now: Date(timeIntervalSince1970: 1_812_998_400))
        let insights = AgentMeterPhoneInsights(snapshot: snapshot)

        XCTAssertEqual(insights.totals(for: .currentSession).tokens, 670_000)
        XCTAssertEqual(try XCTUnwrap(insights.totals(for: .currentSession).costUSD), 6.98, accuracy: 0.0001)
        XCTAssertEqual(insights.totals(for: .weekly).tokens, 1_720_000)
        XCTAssertEqual(try XCTUnwrap(insights.totals(for: .weekly).costUSD), 17.93, accuracy: 0.0001)
        XCTAssertEqual(insights.totals(for: .all).tokens, 13_500_000)
        XCTAssertEqual(try XCTUnwrap(insights.totals(for: .all).costUSD), 128.60, accuracy: 0.0001)
        XCTAssertNil(insights.totals(for: .fullTime).tokens)
        XCTAssertNil(insights.totals(for: .fullTime).costUSD)
    }

    func test_formatterUsesNAForUnavailableMetricValues() throws {
        XCTAssertEqual(AgentMeterFormat.compactNumber(nil), "NA")
        XCTAssertEqual(AgentMeterFormat.money(nil), "NA")
        XCTAssertEqual(AgentMeterFormat.percent(nil), "NA")
    }

    func test_agentMeterIdentityUsesOwnMarkInsteadOfProviderIcon() throws {
        XCTAssertEqual(AgentMeterIdentityAsset.imageName, "AgentMeterIdentityIcon")
        XCTAssertNil(AgentMeterProviderAsset.iconName(for: "agentmeter"))
        XCTAssertEqual(AgentMeterProviderAsset.iconName(for: "claudeCode"), "ClaudeCodeIcon")
    }

    func test_resetTextUsesResetsAtAndDoesNotDuplicatePrefixes() throws {
        let now = Date(timeIntervalSince1970: 1_812_998_400)
        let window = AgentMeterPhoneUsageWindow(
            id: "session",
            title: "Session",
            usedPercent: 20,
            remainingPercent: 80,
            resetsAt: now.addingTimeInterval(90 * 60),
            resetDescription: "Resets in 2h",
            windowMinutes: 300)

        XCTAssertEqual(AgentMeterFormat.resetText(for: window, from: now), "Resets in 1h 30m")
        XCTAssertEqual(
            AgentMeterFormat.resetText(resetsAt: nil, resetDescription: "2h", from: now),
            "Resets in 2h")
        XCTAssertEqual(
            AgentMeterFormat.resetText(resetsAt: nil, resetDescription: "Resets in 2h", from: now),
            "Resets in 2h")
        XCTAssertEqual(
            AgentMeterFormat.resetText(resetsAt: nil, resetDescription: "Jun 17 at 2:19AM", from: now),
            "Resets Jun 17 at 2:19AM")
        XCTAssertEqual(
            AgentMeterFormat.resetMetricText(resetsAt: window.resetsAt, resetDescription: window.resetDescription, from: now),
            "1h 30m")
        XCTAssertEqual(
            AgentMeterFormat.resetMetricText(resetsAt: nil, resetDescription: "Jun 17 at 2:19AM", from: now),
            "Jun 17 at 2:19AM")
    }

    func test_paceProjectionShowsEmptyBeforeResetWhenUsageRateIsTooHigh() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_812_998_400)
        let window = AgentMeterPhoneUsageWindow(
            id: "session",
            title: "Session",
            usedPercent: 50,
            remainingPercent: 50,
            resetsAt: generatedAt.addingTimeInterval(2 * 60 * 60),
            resetDescription: "2h",
            windowMinutes: 180)

        let projection = try XCTUnwrap(window.paceProjection(generatedAt: generatedAt))

        XCTAssertTrue(projection.emptiesBeforeReset)
        XCTAssertEqual(projection.markerPercent, 2.0 / 3.0, accuracy: 0.0001)
    }

    func test_defaultURLUsesFallbackWhenAppGroupIsNotConfigured() throws {
        let fileManager = FileManager.default

        let defaultURL = AgentMeterPhoneSnapshotStore.defaultURL(
            fileManager: fileManager,
            infoDictionary: [AgentMeterPhoneSnapshotStore.appGroupIdentifierInfoKey: ""])

        XCTAssertEqual(defaultURL, AgentMeterPhoneSnapshotStore.fallbackURL(fileManager: fileManager))
    }

    func test_configuredAppGroupIdentifierAcceptsOnlyGroupPrefixedValues() throws {
        XCTAssertNil(AgentMeterPhoneSnapshotStore.configuredAppGroupIdentifier(infoDictionary: [:]))
        XCTAssertNil(AgentMeterPhoneSettings.configuredAppGroupIdentifier(infoDictionary: [:]))
        XCTAssertNil(AgentMeterPhoneSnapshotStore.configuredAppGroupIdentifier(infoDictionary: [
            AgentMeterPhoneSnapshotStore.appGroupIdentifierInfoKey: "  ",
        ]))
        XCTAssertNil(AgentMeterPhoneSnapshotStore.configuredAppGroupIdentifier(infoDictionary: [
            AgentMeterPhoneSnapshotStore.appGroupIdentifierInfoKey: "TEAM123456.com.zain.agentmeter",
        ]))
        XCTAssertNil(AgentMeterPhoneSnapshotStore.configuredAppGroupIdentifier(infoDictionary: [
            AgentMeterPhoneSnapshotStore.appGroupIdentifierInfoKey: "group.",
        ]))
        XCTAssertEqual(
            AgentMeterPhoneSnapshotStore.configuredAppGroupIdentifier(infoDictionary: [
                AgentMeterPhoneSnapshotStore.appGroupIdentifierInfoKey: " group.com.zain.agentmeter.dev ",
            ]),
            "group.com.zain.agentmeter.dev")
        XCTAssertEqual(
            AgentMeterPhoneSettings.configuredAppGroupIdentifier(infoDictionary: [
                AgentMeterPhoneSnapshotStore.appGroupIdentifierInfoKey: " group.com.zain.agentmeter.dev ",
            ]),
            "group.com.zain.agentmeter.dev")
    }

    func test_activitySnapshotIsSmallAndCombined() throws {
        #if canImport(ActivityKit)
        let snapshot = AgentMeterActivitySnapshot(snapshot: AgentMeterSampleData.snapshot())

        XCTAssertEqual(snapshot.providers.map(\.id), ["claude", "codex"])
        XCTAssertEqual(snapshot.providers.count, 2)
        XCTAssertEqual(snapshot.peakSessionUsedPercent, 42)

        let claude = try XCTUnwrap(snapshot.providers.first { $0.id == "claude" })
        XCTAssertEqual(claude.sessionWindow?.id, "session")
        XCTAssertEqual(claude.sessionWindow?.title, "Session")
        XCTAssertEqual(claude.sessionWindow?.usedPercent, 42)
        XCTAssertEqual(claude.weeklyWindow?.id, "weekly")
        XCTAssertEqual(claude.weeklyWindow?.title, "Weekly")
        XCTAssertEqual(claude.weeklyWindow?.usedPercent, 63)

        let codex = try XCTUnwrap(snapshot.providers.first { $0.id == "codex" })
        XCTAssertEqual(codex.sessionWindow?.id, "session")
        XCTAssertEqual(codex.sessionWindow?.title, "Session")
        XCTAssertEqual(codex.sessionWindow?.usedPercent, 24)
        XCTAssertEqual(codex.weeklyWindow?.id, "weekly")
        XCTAssertEqual(codex.weeklyWindow?.title, "Weekly")
        XCTAssertEqual(codex.weeklyWindow?.usedPercent, 51)
        #endif
    }

    func test_dailyUsageChartKeepsLatestSevenDaysAndNormalizesByTokens() throws {
        let points = (1...9).map { day in
            AgentMeterPhoneDailyUsagePoint(
                dayKey: "2026-06-\(String(format: "%02d", day))",
                totalTokens: day * 100,
                costUSD: Double(day))
        }

        let model = AgentMeterDailyUsageChartModel(dailyUsage: points)

        XCTAssertEqual(model.points.map(\.dayKey), [
            "2026-06-03",
            "2026-06-04",
            "2026-06-05",
            "2026-06-06",
            "2026-06-07",
            "2026-06-08",
            "2026-06-09",
        ])
        XCTAssertEqual(model.points.last?.normalizedHeight, 1)
        XCTAssertEqual(model.points.first?.shortLabel, "03")
        XCTAssertEqual(model.totalTokens, 4_200)
        XCTAssertEqual(model.totalCostUSD, 42)
    }

    func test_dailyUsageChartFallsBackToCostWhenTokensAreMissing() throws {
        let points = [
            AgentMeterPhoneDailyUsagePoint(dayKey: "2026-06-12", totalTokens: nil, costUSD: 1.5),
            AgentMeterPhoneDailyUsagePoint(dayKey: "2026-06-13", totalTokens: nil, costUSD: 3.0),
        ]

        let model = AgentMeterDailyUsageChartModel(dailyUsage: points)

        XCTAssertNil(model.totalTokens)
        XCTAssertEqual(model.totalCostUSD, 4.5)
        XCTAssertEqual(model.points.map(\.normalizedHeight), [0.5, 1.0])
    }

    func test_phoneInsightsAggregatePrimarySnapshot() throws {
        let snapshot = AgentMeterSampleData.snapshot(now: Date(timeIntervalSince1970: 1_812_998_400))

        let insights = AgentMeterPhoneInsights(snapshot: snapshot)

        XCTAssertEqual(insights.providerCount, 2)
        XCTAssertEqual(insights.attentionProviderCount, 0)
        XCTAssertEqual(insights.totalSessionTokens, 670_000)
        XCTAssertEqual(try XCTUnwrap(insights.totalSessionCostUSD), 6.98, accuracy: 0.0001)
        XCTAssertEqual(insights.currencyCode, "USD")
        XCTAssertEqual(insights.peakSessionUsage?.providerID, "claude")
        XCTAssertEqual(insights.peakSessionUsage?.usedPercent, 42)
        XCTAssertEqual(insights.nextReset?.providerID, "claude")
        XCTAssertEqual(insights.combinedDailyUsage.count, 3)
        XCTAssertEqual(insights.combinedDailyUsage.first?.dayKey, "2026-06-12")
        XCTAssertEqual(insights.combinedDailyUsage.last?.dayKey, "2026-06-14")
        XCTAssertEqual(insights.combinedDailyUsage.last?.totalTokens, 670_000)
        XCTAssertEqual(try XCTUnwrap(insights.combinedDailyUsage.last?.costUSD), 6.98, accuracy: 0.0001)
    }
}

private extension JSONDecoder {
    static var agentMeter: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

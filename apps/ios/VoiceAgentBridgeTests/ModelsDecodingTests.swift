import XCTest
@testable import VoiceAgentBridge

final class ModelsDecodingTests: XCTestCase {
    func testInitialSyncRequiredForcesSnapshotOnlyBeforeCursorIsEstablished() {
        XCTAssertTrue(AppStore.shouldForceSnapshot(eventName: "sync.required", appliedCursor: nil))
        XCTAssertTrue(AppStore.shouldForceSnapshot(eventName: "sync.required", appliedCursor: "  "))
        XCTAssertFalse(AppStore.shouldForceSnapshot(eventName: "sync.required", appliedCursor: "2030"))
        XCTAssertFalse(AppStore.shouldForceSnapshot(eventName: "session.updated", appliedCursor: nil))
    }

    func testRuntimeApiOverrideNeverPollutesPersistedServerSelection() {
        XCTAssertFalse(AppStore.shouldPersistApiBase(
            runtimeOverride: "https://127.0.0.1:9",
            persistedApiBase: nil,
            resolvedApiBase: "https://127.0.0.1:9"
        ))
        XCTAssertFalse(AppStore.shouldPersistApiBase(
            runtimeOverride: nil,
            persistedApiBase: "https://saved.example.com",
            resolvedApiBase: "https://saved.example.com"
        ))
        XCTAssertTrue(AppStore.shouldPersistApiBase(
            runtimeOverride: nil,
            persistedApiBase: nil,
            resolvedApiBase: "https://bundled.example.com"
        ))
    }

    func testPhysicalDeviceRegistrationRequiresValidAPNsToken() throws {
        XCTAssertThrowsError(
            try APIClient.deviceRegistration(pushToken: nil, isSimulator: false)
        ) { error in
            guard case APIClientError.missingPushToken = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(
            try APIClient.deviceRegistration(pushToken: "dev-placeholder", isSimulator: false)
        ) { error in
            guard case APIClientError.invalidPushToken = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let token = String(repeating: "A1", count: 32)
        let registration = try APIClient.deviceRegistration(
            pushToken: token,
            isSimulator: false
        )
        XCTAssertEqual(registration.platform, "ios")
        XCTAssertEqual(registration.token, token.lowercased())
    }

    func testSimulatorMayUseNonAPNsFixtureToken() throws {
        let registration = try APIClient.deviceRegistration(
            pushToken: nil,
            isSimulator: true
        )
        XCTAssertEqual(registration.platform, "ios_simulator")
        XCTAssertTrue(registration.token.hasPrefix("sim-"))
    }

    func testCommandScopeDeviceIDAcceptsBackendRowIDAndRejectsInstallationID() {
        XCTAssertEqual(
            APIClient.commandScopeDeviceID(
                fromRegistration: "dev_0123456789abcdef0123456789abcdef"
            ),
            "dev_0123456789abcdef0123456789abcdef"
        )
        XCTAssertEqual(
            APIClient.commandScopeDeviceID(
                fromRegistration: "  DEV_0123456789ABCDEF0123456789ABCDEF  "
            ),
            "DEV_0123456789ABCDEF0123456789ABCDEF"
        )
        XCTAssertNil(
            APIClient.commandScopeDeviceID(
                fromRegistration: "ios-11111111-1111-1111-1111-111111111111"
            )
        )
        XCTAssertNil(APIClient.commandScopeDeviceID(fromRegistration: "dev_short"))
        XCTAssertNil(APIClient.commandScopeDeviceID(fromRegistration: " "))
    }

    func testDeviceRegistrationResponseDecodesBackendRowID() throws {
        let response = try decoder.decode(
            DeviceRegistrationResponse.self,
            from: Data(
                """
                {
                  "device_id": "dev_0123456789abcdef0123456789abcdef",
                  "platform": "ios",
                  "push_token_registered": true,
                  "locale": "en-US",
                  "timezone": "Asia/Hong_Kong"
                }
                """.utf8
            )
        )
        XCTAssertEqual(
            APIClient.commandScopeDeviceID(fromRegistration: response.device_id),
            "dev_0123456789abcdef0123456789abcdef"
        )
        XCTAssertTrue(response.push_token_registered)
    }

    private let decoder = JSONDecoder()

    func testLegacyFixtureEmailMigrationIsScoped() {
        XCTAssertTrue(DemoConfig.isLegacyDemoEmail("E2E-1785931570@LOCAL.TEST"))
        XCTAssertFalse(DemoConfig.isLegacyDemoEmail("user@example.com"))
    }

    func testDebugApiBaseOverridePrecedesPersistedSimulatorEndpoint() {
        let override = DemoConfig.runtimeApiBaseOverride(environment: [
            "KNOCK_UI_TEST_API_BASE_URL": "http://127.0.0.1:8798",
            "KNOCK_API_BASE_URL": "http://127.0.0.1:8797"
        ])

        #if DEBUG
        XCTAssertEqual(override, "http://127.0.0.1:8798")
        #else
        XCTAssertNil(override)
        #endif
    }

    func testUnresolvedApiBaseBuildSettingIsIgnored() {
        let override = DemoConfig.runtimeApiBaseOverride(environment: [
            "KNOCK_UI_TEST_API_BASE_URL": "$(KNOCK_API_BASE_URL)"
        ])

        XCTAssertNil(override)
    }

    func testProductionDrawerScrollAnchorStaysAtViewportTopAndFallsBack() {
        let recent = ProductionDrawerScrollAnchors.recentSection
        let positions = [
            ProductionDrawerScrollAnchors.pinnedSection: CGFloat(-260),
            ProductionDrawerScrollAnchors.workspaceSection: CGFloat(-88),
            recent: CGFloat(-18),
            ProductionDrawerScrollAnchors.recentSession("session-visible"): CGFloat(9),
        ]

        XCTAssertEqual(
            ProductionDrawerScrollAnchors.preferredAnchor(from: positions),
            recent
        )
        XCTAssertEqual(
            ProductionDrawerScrollAnchors.restoredAnchor(
                current: "removed-session",
                available: [recent]
            ),
            recent
        )
        XCTAssertEqual(
            ProductionDrawerScrollAnchors.restoredAnchor(
                current: ProductionDrawerScrollAnchors.pinnedSession("removed"),
                available: [ProductionDrawerScrollAnchors.pinnedSection, recent]
            ),
            ProductionDrawerScrollAnchors.pinnedSection
        )
        XCTAssertNil(
            ProductionDrawerScrollAnchors.restoredAnchor(
                current: nil,
                available: [recent]
            )
        )
        XCTAssertEqual(
            ProductionDrawerScrollAnchors.restoredAnchor(
                current: "session-still-present",
                available: [recent, "session-still-present"]
            ),
            "session-still-present"
        )
    }

    func testReleaseEndpointPolicyMigratesDevelopmentAddress() {
        XCTAssertTrue(
            DemoConfig.isLegacyDevelopmentApiBase(
                "http://10.0.0.1:8787",
                requireHTTPS: true
            )
        )
        XCTAssertTrue(
            DemoConfig.isLegacyDevelopmentApiBase(
                "http://127.0.0.1:8787",
                requireHTTPS: true
            )
        )
        XCTAssertFalse(
            DemoConfig.isLegacyDevelopmentApiBase(
                DemoConfig.productionApiBase,
                requireHTTPS: true
            )
        )
        XCTAssertFalse(
            DemoConfig.isLegacyDevelopmentApiBase(
                "https://custom.example.com",
                requireHTTPS: true
            )
        )
        XCTAssertFalse(DemoConfig.isValidApiBase("http://127.0.0.1:8787", requireHTTPS: true))
        XCTAssertTrue(DemoConfig.isValidApiBase(DemoConfig.productionApiBase, requireHTTPS: true))
    }

    func testPhoneSessionsDecodeSnakeCasePayload() throws {
        let data = Data(
            """
            {
              "sessions": [{
                "session_id": "ses_test",
                "agent_id": "agt_test",
                "skill_id": "deploy.result",
                "state": "needs_user",
                "progress_status": "running",
                "progress_percent": 42,
                "progress_message": "waiting for confirmation",
                "chat_id": "chat_test",
                "title": "Deploy API",
                "summary_text": "api 在 prod 部署失败",
                "voice_script": "api 在 prod 部署失败",
                "available_actions": ["rollback", "ack"],
                "available_action_descriptors": [{
                  "action_key": "rollback",
                  "title": "Rollback production",
                  "risk": "destructive",
                  "confirm_required": true,
                  "payload": {"scope": "prod"}
                }],
                "version": 8,
                "facts": {"service": "api"},
                "expires_at": "2026-08-06T00:00:00.000Z",
                "created_at": "2026-08-05T00:00:00.000Z",
                "updated_at": "2026-08-05T00:01:00.000Z"
              }]
            }
            """.utf8
        )

        let response = try decoder.decode(SessionsResponse.self, from: data)
        let session = try XCTUnwrap(response.sessions.first)

        XCTAssertEqual(session.session_id, "ses_test")
        XCTAssertTrue(session.needsUser)
        XCTAssertEqual(session.progress_percent, 42)
        XCTAssertEqual(session.available_actions, ["rollback", "ack"])
        XCTAssertEqual(session.available_action_descriptors?.first?.action_key, "rollback")
        XCTAssertEqual(session.available_action_descriptors?.first?.title, "Rollback production")
        XCTAssertTrue(session.available_action_descriptors?.first?.confirm_required == true)
        XCTAssertEqual(session.version, 8)
        XCTAssertEqual(session.summary_text, "api 在 prod 部署失败")
        XCTAssertEqual(session.facts["service"]?.displayValue, "api")
    }

    func testPushAndPendingActionDecodeOptionalFields() throws {
        let pushData = Data(
            """
            {
              "pushes": [{
                "push_id": "push_test",
                "session_id": "ses_test",
                "title": "Deploy API",
                "body": "需要确认",
                "voice_script": "需要确认",
                "created_at": "2026-08-05T00:01:00.000Z"
              }]
            }
            """.utf8
        )
        let actionData = Data(
            """
            {
              "action_id": "act_test",
              "session_id": "ses_test",
              "action_key": "rollback",
              "title": "回滚",
              "risk": "destructive",
              "confirm_required": true,
              "status": "pending_confirm",
              "expires_at": "2026-08-05T00:30:00.000Z"
            }
            """.utf8
        )

        let pushResponse = try decoder.decode(DevPushesResponse.self, from: pushData)
        let push = try XCTUnwrap(pushResponse.pushes.first)
        let action = try decoder.decode(PendingAction.self, from: actionData)

        XCTAssertEqual(push.session_id, "ses_test")
        XCTAssertEqual(push.voice_script, "需要确认")
        XCTAssertEqual(action.title, "回滚")
        XCTAssertEqual(action.confirm_required, true)
        XCTAssertEqual(action.risk, "destructive")
    }

    func testSessionFiltersSeparateDecisionQueueFromActiveAndTerminal() throws {
        let data = Data(
            """
            {
              "sessions": [
                {"session_id":"needs","agent_id":"a","skill_id":"deploy","state":"needs_user"},
                {"session_id":"confirm","agent_id":"a","skill_id":"deploy","state":"awaiting_confirm"},
                {"session_id":"working","agent_id":"a","skill_id":"deploy","state":"running"},
                {"session_id":"done","agent_id":"a","skill_id":"deploy","state":"succeeded"}
              ]
            }
            """.utf8
        )

        let sessions = try decoder.decode(SessionsResponse.self, from: data).sessions
        let needsUser = sessions.filter { $0.matches(.needsUser) }
        let active = sessions.filter { $0.matches(.active) }

        XCTAssertEqual(needsUser.map(\.session_id), ["needs", "confirm"])
        XCTAssertEqual(active.map(\.session_id), ["working"])
        XCTAssertEqual(sessions.filter { $0.matches(.all) }.count, 4)
        XCTAssertEqual(sessions[1].stateTitle, "Awaiting confirmation")
        XCTAssertEqual(sessions[2].stateSymbol, "arrow.triangle.2.circlepath")
    }

    func testSessionSearchMatchesAgentTaskStateAndFactsWithMultipleTokens() throws {
        let data = Data(
            #"{"sessions":[{"session_id":"ses_search","agent_id":"agt_codex","skill_id":"deploy.result","state":"needs_user","title":"Deploy API","summary_text":"api 在 prod 部署失败","facts":{"service":"api","environment":"production"}}]}"#.utf8
        )
        let session = try decoder.decode(SessionsResponse.self, from: data).sessions[0]
        let agent = Agent(
            agent_id: "agt_codex",
            user_id: "usr_1",
            label: "Codex Mac",
            host_label: "cursor",
            created_at: "2026-08-05T00:00:00Z",
            last_seen_at: nil
        )

        XCTAssertTrue(SessionSearchMatcher(query: "codex deploy").matches(session, agent: agent))
        XCTAssertTrue(SessionSearchMatcher(query: "production api").matches(session, agent: agent))
        XCTAssertTrue(SessionSearchMatcher(query: "needs decision").matches(session, agent: agent))
        XCTAssertFalse(SessionSearchMatcher(query: "paperclip").matches(session, agent: agent))
    }

    func testDecisionRiskDoesNotInferRiskFromLegacyActionNames() throws {
        let data = Data(
            """
            {
              "session_id":"risk",
              "agent_id":"agent",
              "skill_id":"deploy.result",
              "state":"needs_user",
              "available_actions":["rollback","ack"],
              "facts":{"attempt":2,"production":true}
            }
            """.utf8
        )

        let session = try decoder.decode(Session.self, from: data)

        XCTAssertEqual(DecisionRisk(session: session).title, "Unknown risk")
        XCTAssertEqual(session.facts["attempt"]?.displayValue, "2")
        XCTAssertEqual(session.facts["production"]?.displayValue, "Yes")
    }

    func testAuthRotationAndAgentHistoryPayloadsDecode() throws {
        let auth = try decoder.decode(
            AuthResponse.self,
            from: Data(#"{"user_id":"usr_1","token":"jwt","refresh_token":"vbr_refresh","expires_in":900}"#.utf8)
        )
        let canonicalAuth = try decoder.decode(
            AuthResponse.self,
            from: Data(#"{"access_token":"canonical-jwt","refresh_token":"vbr_refresh_2","expires_in":900,"user":{"id":"usr_2","email":"user@example.com"}}"#.utf8)
        )
        let agents = try decoder.decode(
            AgentsResponse.self,
            from: Data(#"{"agents":[{"agent_id":"agt_1","user_id":"usr_1","label":"Codex","host_label":"codex","created_at":"2026-08-05T00:00:00Z"}]}"#.utf8)
        )
        let history = try decoder.decode(
            HistoryResponse.self,
            from: Data(#"{"entries":[{"audit_id":"aud_1","action":"phone.confirm","session_id":"ses_1","agent_id":"agt_1","metadata":{"action_id":"act_1"},"created_at":"2026-08-05T00:00:00Z"}]}"#.utf8)
        )

        XCTAssertEqual(auth.refresh_token, "vbr_refresh")
        XCTAssertEqual(auth.expires_in, 900)
        XCTAssertEqual(auth.access_token, "jwt")
        XCTAssertEqual(canonicalAuth.token, "canonical-jwt")
        XCTAssertEqual(canonicalAuth.user_id, "usr_2")
        XCTAssertEqual(canonicalAuth.user?.email, "user@example.com")
        XCTAssertEqual(agents.agents.first?.displayLabel, "Codex")
        XCTAssertNil(agents.agents.first?.last_seen_at)
        let seenAgents = try decoder.decode(
            AgentsResponse.self,
            from: Data(#"{"agents":[{"agent_id":"agt_1","user_id":"usr_1","label":"Codex","host_label":"codex","created_at":"2026-08-05T00:00:00Z","last_seen_at":"2026-08-18T00:00:00Z"}]}"#.utf8)
        )
        XCTAssertEqual(seenAgents.agents.first?.last_seen_at, "2026-08-18T00:00:00Z")
        let ask = try decoder.decode(
            PhoneAskResponse.self,
            from: Data(#"{"ask_id":"ask_1","agent_id":"agt_1","user_id":"usr_1","agent_label":"apns-diagnostic","transcript":"Help with APNs","locale":"en-US","session_id":"ses_1","status":"queued","claimed_at":null,"expires_at":"2026-08-19T00:00:00Z","created_at":"2026-08-18T00:00:00Z"}"#.utf8)
        )
        XCTAssertEqual(ask.ask_id, "ask_1")
        XCTAssertEqual(ask.agent_label, "apns-diagnostic")
        XCTAssertEqual(ask.session_id, "ses_1")
        XCTAssertEqual(history.entries.first?.title, "Phone Confirm")
        XCTAssertEqual(history.entries.first?.metadata["action_id"]?.displayValue, "act_1")
    }

    func testPendingOperationPersistsAsCodableOfflineIntent() throws {
        let operation = PendingOperation(
            id: "op_1",
            kind: .confirm,
            session_id: "ses_1",
            action_key: nil,
            action_id: "act_1",
            confirm: true,
            created_at: Date(timeIntervalSince1970: 1_000)
        )
        let data = try JSONEncoder().encode(operation)
        let decoded = try decoder.decode(PendingOperation.self, from: data)
        XCTAssertEqual(decoded, operation)
    }

    func testSQLiteStorePersistsCursorAndPendingQueue() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-knock-\(UUID().uuidString).sqlite")
        defer { removeSQLiteArtifacts(at: url) }

        let store = SQLiteStore(databaseURL: url)
        XCTAssertTrue(store.isAvailable)
        store.saveAppliedCursor("42")
        store.savePendingOperations([
            PendingOperation(
                id: "op_sqlite",
                kind: .reply,
                session_id: "ses_sqlite",
                action_key: "ack",
                action_id: nil,
                confirm: nil,
                created_at: Date(timeIntervalSince1970: 2_000)
            )
        ])

        XCTAssertEqual(store.loadAppliedCursor(), "42")
        XCTAssertEqual(store.loadPendingOperations().map(\.id), ["op_sqlite"])
        store.clearUserData()
        XCTAssertNil(store.loadAppliedCursor())
        XCTAssertTrue(store.loadPendingOperations().isEmpty)
    }

    func testSQLiteStorePersistsCommandConfirmationAndClearsItWithUserData() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-knock-confirmation-\(UUID().uuidString).sqlite")
        defer { removeSQLiteArtifacts(at: url) }

        let store = SQLiteStore(databaseURL: url)
        let confirmation = PendingCommandConfirmation(
            command_id: "cmd_confirm",
            confirmation_token: "ctok_once",
            title: "Send message",
            risk: "high",
            confirm_required: true,
            reversible: false
        )
        store.savePendingCommandConfirmation(confirmation)

        XCTAssertEqual(store.loadPendingCommandConfirmation(), confirmation)
        store.clearUserData()
        XCTAssertNil(store.loadPendingCommandConfirmation())
    }

    func testAPIErrorDecoderAcceptsCanonicalAndLegacyEnvelopes() throws {
        let decoder = JSONDecoder()
        let canonical = try decoder.decode(
            APIErrorBody.self,
            from: Data(#"{"error":{"code":"invalid_command","message":"bad args","retryable":true,"request_id":"req_1","retry_after":60}}"#.utf8)
        )
        XCTAssertEqual(canonical.error, "invalid_command")
        XCTAssertEqual(canonical.message, "bad args")
        XCTAssertEqual(canonical.retryable, true)
        XCTAssertEqual(canonical.request_id, "req_1")
        XCTAssertEqual(canonical.retry_after, 60)

        let legacy = try decoder.decode(
            APIErrorBody.self,
            from: Data(#"{"error":"legacy_error","message":"old backend"}"#.utf8)
        )
        XCTAssertEqual(legacy.error, "legacy_error")
        XCTAssertEqual(legacy.message, "old backend")
        XCTAssertNil(legacy.retryable)

        let failure = APIClientError.badStatus(
            429,
            "Too many requests",
            APIErrorMetadata(retryable: true, retryAfter: 17, requestID: "req_2")
        )
        if case let .badStatus(code, _, metadata) = failure {
            XCTAssertEqual(code, 429)
            XCTAssertTrue(metadata.retryable)
            XCTAssertEqual(metadata.retryAfter, 17)
            XCTAssertEqual(metadata.requestID, "req_2")
        } else {
            XCTFail("Expected structured status error")
        }
        XCTAssertFalse(
            AppStore.shouldRetryPendingOperation(
                APIClientError.badStatus(
                    422,
                    "Invalid command",
                    APIErrorMetadata(retryable: false, retryAfter: nil, requestID: nil)
                )
            )
        )
        XCTAssertTrue(
            AppStore.shouldRetryPendingOperation(
                APIClientError.badStatus(
                    429,
                    "Too many requests",
                    APIErrorMetadata(retryable: true, retryAfter: 2, requestID: nil)
                )
            )
        )
    }

    func testPermanentPendingFailureRemainsVisibleForRetryOrDiscard() {
        let operation = PendingOperation(
            idempotencyKey: "idem-visible-failure",
            kind: .reply,
            session_id: "ses_visible_failure",
            action_key: "approve",
            action_id: nil,
            confirm: nil,
            created_at: Date(),
            status: .inFlight
        )
        let error = APIClientError.badStatus(
            422,
            "Invalid action",
            APIErrorMetadata(retryable: false, retryAfter: nil, requestID: "req_visible")
        )

        let failed = AppStore.pendingOperationAfterPermanentFailure(operation, error: error)

        XCTAssertEqual(failed.id, operation.id)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.failureCode, "http_422")
        XCTAssertEqual(failed.lastError, error.localizedDescription)
        XCTAssertFalse(failed.isPending)
    }

    func testPendingRetryCoordinatorQueuesManualRetryDuringActivePass() {
        var coordinator = PendingRetryCoordinator()

        XCTAssertTrue(coordinator.beginOrRequestRerun())
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertFalse(coordinator.beginOrRequestRerun())
        XCTAssertTrue(coordinator.rerunRequested)
        XCTAssertTrue(coordinator.consumeRerun())
        XCTAssertFalse(coordinator.consumeRerun())

        coordinator.finish()
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertTrue(coordinator.beginOrRequestRerun())
    }

    func testHistorySearchQueryMatchesOneToTwoHundredCharacterContract() {
        XCTAssertEqual(AppStore.normalizedHistorySearchQuery(" x "), "x")
        XCTAssertEqual(AppStore.normalizedHistorySearchQuery(" 家 "), "家")
        XCTAssertNil(AppStore.normalizedHistorySearchQuery("   "))
        XCTAssertNil(AppStore.normalizedHistorySearchQuery(String(repeating: "x", count: 201)))
    }

    func testHistoryRetrievalAndPushReadModelsDecode() throws {
        let page = try decoder.decode(
            MessagePage.self,
            from: Data(#"{"messages":[{"message_id":"msg_1","session_id":"ses_1","role":"agent","content":"done","metadata":{"source":"worker"},"command_id":null,"sequence":1,"created_at":"2026-08-09T00:00:00Z"}],"next_cursor":"cursor-1","has_more":false}"#.utf8)
        )
        let detail = try decoder.decode(
            SessionDetailResponse.self,
            from: Data(#"{"session_id":"ses_1","agent_id":"agt_1","skill_id":"research","state":"closed","summary_text":"done","facts":{"answer":"yes"},"retrieval_items":[{"retrieval_id":"ret_1","session_id":"ses_1","message_id":"msg_1","title":"Source","url":"https://example.com","snippet":"snapshot","score":0.9,"content_hash":"sha","created_at":"2026-08-09T00:00:00Z"}],"created_at":"2026-08-09T00:00:00Z","updated_at":"2026-08-09T00:00:00Z"}"#.utf8)
        )
        let push = try decoder.decode(
            DevPush.self,
            from: Data(#"{"push_id":"push_1","session_id":"ses_1","title":"Done","body":"finished","voice_script":null,"created_at":"2026-08-09T00:00:00Z","read_at":"2026-08-09T00:01:00Z","dismissed_at":null}"#.utf8)
        )

        XCTAssertEqual(page.messages.first?.content, "done")
        let legacyPage = try decoder.decode(
            MessagePage.self,
            from: Data(#"{"items":[{"message_id":"msg_legacy","session_id":"ses_1","role":"agent","content":"old","metadata":{},"command_id":null,"sequence":1,"created_at":"2026-08-09T00:00:00Z"}],"next_cursor":null}"#.utf8)
        )
        XCTAssertEqual(legacyPage.messages.first?.message_id, "msg_legacy")
        XCTAssertEqual(detail.retrieval_items.first?.content_hash, "sha")
        XCTAssertNotNil(push.read_at)
    }

    func testSessionAndHistoryPaginationFieldsDecodeWithLegacyDefaults() throws {
        let sessionPage = try decoder.decode(
            SessionsResponse.self,
            from: Data(#"{"sessions":[{"session_id":"ses_1","agent_id":"agt_1","skill_id":"research","state":"running"}],"next_cursor":"session-cursor","has_more":true}"#.utf8)
        )
        let legacySessionPage = try decoder.decode(
            SessionsResponse.self,
            from: Data(#"{"sessions":[]}"#.utf8)
        )
        let historyPage = try decoder.decode(
            HistoryResponse.self,
            from: Data(#"{"entries":[],"next_cursor":"history-cursor","has_more":true}"#.utf8)
        )

        XCTAssertEqual(sessionPage.sessions.first?.session_id, "ses_1")
        XCTAssertEqual(sessionPage.next_cursor, "session-cursor")
        XCTAssertTrue(sessionPage.has_more)
        XCTAssertNil(legacySessionPage.next_cursor)
        XCTAssertFalse(legacySessionPage.has_more)
        XCTAssertEqual(historyPage.next_cursor, "history-cursor")
        XCTAssertTrue(historyPage.has_more)
    }

    func testSQLiteStoreCachesMessagesAndRetrievals() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-knock-history-\(UUID().uuidString).sqlite")
        defer { removeSQLiteArtifacts(at: url) }

        let store = SQLiteStore(databaseURL: url)
        let message = SessionMessage(
            message_id: "msg_sqlite",
            session_id: "ses_sqlite",
            role: "agent",
            content: "cached",
            metadata: [:],
            command_id: nil,
            sequence: 1,
            created_at: "2026-08-09T00:00:00Z"
        )
        let retrieval = RetrievalItem(
            retrieval_id: "ret_sqlite",
            session_id: "ses_sqlite",
            message_id: message.message_id,
            title: "Source",
            url: "https://example.com",
            snippet: "cached source",
            score: 0.8,
            content_hash: "hash",
            created_at: message.created_at
        )
        store.cacheMessages([message], for: message.session_id)
        store.cacheRetrievals([retrieval], for: retrieval.session_id)

        XCTAssertEqual(store.loadMessages(for: "ses_sqlite").map(\.message_id), ["msg_sqlite"])
        XCTAssertEqual(store.loadRetrievals(for: "ses_sqlite").map(\.retrieval_id), ["ret_sqlite"])
        store.removeMessage(message.message_id)
        store.removeRetrieval(retrieval.retrieval_id)
        XCTAssertTrue(store.loadMessages(for: "ses_sqlite").isEmpty)
        XCTAssertTrue(store.loadRetrievals(for: "ses_sqlite").isEmpty)
    }

    func testPendingOperationUsesStableIdempotencyKeyAndExplicitTransitions() throws {
        let operation = PendingOperation(
            idempotencyKey: "idem_stable",
            kind: .reply,
            session_id: "ses_transition",
            action_key: "ack",
            action_id: nil,
            confirm: nil,
            created_at: Date(timeIntervalSince1970: 3_000),
            status: .inFlight
        )
        XCTAssertEqual(operation.id, "idem_stable")
        XCTAssertTrue(operation.isPending)
        XCTAssertEqual(PendingOperation.Status.allCases.map(\.rawValue), ["pending", "in_flight", "failed"])

        let legacy = try decoder.decode(
            PendingOperation.self,
            from: Data(
                #"{"id":"legacy_idem","kind":"reply","session_id":"ses_legacy","action_key":"ack","created_at":"2026-08-09T00:00:00Z"}"#.utf8
            )
        )
        XCTAssertEqual(legacy.idempotency_key, "legacy_idem")
        XCTAssertEqual(legacy.status, .pending)
    }

    func testPendingOperationCoalescesOnlyAnUnfinishedSemanticIntent() {
        let pending = PendingOperation(
            idempotencyKey: "idem_pending",
            kind: .reply,
            session_id: "ses_coalesce",
            action_key: "ack",
            action_id: nil,
            confirm: nil,
            created_at: Date(timeIntervalSince1970: 3_100)
        )
        let duplicate = PendingOperation(
            idempotencyKey: "idem_new",
            kind: .reply,
            session_id: pending.session_id,
            action_key: pending.action_key,
            action_id: nil,
            confirm: nil,
            created_at: Date(timeIntervalSince1970: 3_101)
        )
        var failed = pending
        failed.status = .failed

        XCTAssertTrue(AppStore.coalescesPendingIntent(pending, duplicate))
        XCTAssertFalse(AppStore.coalescesPendingIntent(failed, duplicate))
        XCTAssertNotEqual(pending.id, duplicate.id)
    }

    func testSQLiteStoreReopensCachesCursorAndRecoversInFlightIntent() throws {
        let url = temporarySQLiteURL("restart")
        defer { removeSQLiteArtifacts(at: url) }
        let session = try decoder.decode(
            Session.self,
            from: Data(
                #"{"session_id":"ses_restart","agent_id":"agt_1","skill_id":"research","state":"needs_user","facts":{"offline":true},"created_at":"2026-08-09T00:00:00Z","updated_at":"2026-08-09T00:00:00Z"}"#.utf8
            )
        )
        let push = try decoder.decode(
            DevPush.self,
            from: Data(
                #"{"push_id":"push_restart","session_id":"ses_restart","title":"Offline","body":"queued","created_at":"2026-08-09T00:00:00Z"}"#.utf8
            )
        )
        let operation = PendingOperation(
            idempotencyKey: "idem_restart",
            kind: .confirm,
            session_id: "ses_restart",
            action_key: nil,
            action_id: "act_restart",
            confirm: true,
            created_at: Date(timeIntervalSince1970: 4_000),
            status: .inFlight
        )

        do {
            let store = SQLiteStore(databaseURL: url)
            XCTAssertTrue(store.isAvailable)
            store.cacheSessions([session])
            store.cachePushes([push])
            store.saveCursor("received-1")
            store.saveAppliedCursor("applied-1")
            XCTAssertTrue(store.savePendingOperations([operation]))
        }

        do {
            let reopened = SQLiteStore(databaseURL: url)
            XCTAssertEqual(reopened.loadSessions().map(\.session_id), ["ses_restart"])
            XCTAssertEqual(reopened.loadPushes().map(\.push_id), ["push_restart"])
            XCTAssertEqual(reopened.loadCursor(), "received-1")
            XCTAssertEqual(reopened.loadAppliedCursor(), "applied-1")
            let recovered = try XCTUnwrap(reopened.loadPendingOperations().first)
            XCTAssertEqual(recovered.idempotency_key, "idem_restart")
            XCTAssertEqual(recovered.status, .pending)
            XCTAssertTrue(recovered.isPending)
        }
    }

    func testSQLiteStoreReopensAndClearsActiveCommandCheckpoint() throws {
        let url = temporarySQLiteURL("active-command")
        defer { removeSQLiteArtifacts(at: url) }
        let envelope = try CommandEnvelope(
            commandID: "cmd_voice_restart",
            intent: "search_history",
            args: ["q": .string("history")],
            riskLevel: .low,
            needsConfirmation: false,
            idempotencyKey: "idem_voice_restart",
            confidence: 0.97,
            locale: "en-HK",
            timezone: "Asia/Hong_Kong"
        )
        let checkpoint = ActiveCommandCheckpoint(
            phase: .submitting,
            commandID: envelope.commandID,
            backendState: nil,
            backendVersion: nil,
            envelope: envelope,
            validatedPresentation: nil,
            lastAnnouncedVersion: nil,
            backendOrigin: "https://api.example.com:443",
            ownerUserID: "usr_restart",
            createdAt: Date(timeIntervalSince1970: 4_100)
        )

        do {
            let store = SQLiteStore(databaseURL: url)
            XCTAssertTrue(store.saveActiveCommandCheckpoint(checkpoint))
            XCTAssertEqual(store.loadActiveCommandCheckpoint(), checkpoint)
        }

        do {
            let reopened = SQLiteStore(databaseURL: url)
            XCTAssertEqual(reopened.loadActiveCommandCheckpoint(), checkpoint)
            XCTAssertTrue(reopened.clearActiveCommandCheckpoint())
            XCTAssertNil(reopened.loadActiveCommandCheckpoint())
        }
    }

    func testSQLiteStoreDeduplicatesQueuedEventsAndCommitsOnlyConsumedEvents() throws {
        let url = temporarySQLiteURL("events")
        defer { removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        XCTAssertTrue(store.recordPendingSyncEvent(
            eventID: "event-1",
            eventName: "session.updated",
            receivedAt: Date(timeIntervalSince1970: 1)
        ))
        XCTAssertTrue(store.recordPendingSyncEvent(
            eventID: "event-1",
            eventName: "session.updated",
            receivedAt: Date(timeIntervalSince1970: 2)
        ))
        XCTAssertTrue(store.recordPendingSyncEvent(
            eventID: "event-2",
            eventName: "message.created",
            receivedAt: Date(timeIntervalSince1970: 3)
        ))
        XCTAssertEqual(store.loadPendingSyncEvents().map(\.event_id), ["event-1", "event-2"])
        XCTAssertNil(store.loadAppliedCursor())

        // event-2 represents an invalidation received while the first REST
        // pass was in flight; consuming event-1 must not drop it.
        XCTAssertTrue(store.commitReconciliation(
            cursor: "cursor-1",
            resetCursor: false,
            consumedEventIDs: ["event-1"]
        ))
        XCTAssertEqual(store.loadPendingSyncEvents().map(\.event_id), ["event-2"])
        XCTAssertEqual(store.loadAppliedCursor(), "cursor-1")
        XCTAssertEqual(store.loadCursor(), "event-2")

        XCTAssertTrue(store.commitReconciliation(
            cursor: "cursor-2",
            resetCursor: false,
            consumedEventIDs: ["event-2"]
        ))
        XCTAssertTrue(store.loadPendingSyncEvents().isEmpty)
        XCTAssertEqual(store.loadAppliedCursor(), "cursor-2")

        XCTAssertTrue(store.commitReconciliation(
            cursor: nil,
            resetCursor: true,
            consumedEventIDs: []
        ))
        XCTAssertNil(store.loadCursor())
        XCTAssertNil(store.loadAppliedCursor())
    }

    func testLegacyUserDefaultsPendingFixtureMigratesToSQLiteOnce() throws {
        let url = temporarySQLiteURL("legacy")
        defer { removeSQLiteArtifacts(at: url) }
        let pendingKey = "vab.test.pending.\(UUID().uuidString)"
        let cursorKey = "vab.test.cursor.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: pendingKey)
            UserDefaults.standard.removeObject(forKey: cursorKey)
        }
        let legacy = Data(
            #"[{"id":"legacy-op","kind":"confirm","session_id":"ses_legacy","action_id":"act_legacy","confirm":true,"created_at":"2026-08-09T00:00:00Z"}]"#.utf8
        )
        UserDefaults.standard.set(legacy, forKey: pendingKey)
        UserDefaults.standard.set("legacy-cursor", forKey: cursorKey)

        let store = SQLiteStore(databaseURL: url)
        store.migrateLegacyState(pendingKey: pendingKey, cursorKey: cursorKey)
        XCTAssertEqual(store.loadPendingOperations().map(\.idempotency_key), ["legacy-op"])
        XCTAssertEqual(store.loadAppliedCursor(), "legacy-cursor")
        XCTAssertNil(UserDefaults.standard.data(forKey: pendingKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: cursorKey))
    }

    func testSyncGapPayloadRequestsFullSyncWithCursorResume() throws {
        let response = try decoder.decode(
            SyncResponse.self,
            from: Data(
                #"{"cursor":"cursor-9","next_cursor":"cursor-10","changes":[],"has_more":false,"gap":true}"#.utf8
            )
        )
        XCTAssertTrue(response.requiresFullSync)
        XCTAssertEqual(response.effectiveNextCursor, "cursor-10")
    }

    func testSSEParserCoalescesDataLinesAndPreservesEventID() throws {
        var parser = ServerSentEventParser()
        XCTAssertNil(parser.consume(": heartbeat"))
        XCTAssertNil(parser.consume("id: event-42"))
        XCTAssertNil(parser.consume("event: sync.required"))
        XCTAssertNil(parser.consume("data: {"))
        XCTAssertNil(parser.consume("data: \"reason\":\"gap\"}"))
        let event = try XCTUnwrap(parser.consume(""))
        XCTAssertEqual(event.id, "event-42")
        XCTAssertEqual(event.name, "sync.required")
        XCTAssertEqual(event.data, "{\n\"reason\":\"gap\"}")
    }

    func testSSEResumeHeadersAndForegroundLifecycleGate() {
        let headers = APIClient.eventStreamResumeHeaders(since: "cursor resume")
        XCTAssertEqual(headers["Accept"], "text/event-stream")
        XCTAssertEqual(headers["Last-Event-ID"], "cursor resume")
        XCTAssertNil(APIClient.eventStreamResumeHeaders(since: nil)["Last-Event-ID"])

        XCTAssertTrue(
            AppStore.shouldOpenEventStream(
                tokenAvailable: true,
                needsForegroundReconciliation: false,
                streamExists: false,
                reconciliationExists: false
            )
        )
        XCTAssertFalse(
            AppStore.shouldOpenEventStream(
                tokenAvailable: true,
                needsForegroundReconciliation: true,
                streamExists: false,
                reconciliationExists: false
            )
        )
        XCTAssertFalse(
            AppStore.shouldOpenEventStream(
                tokenAvailable: true,
                needsForegroundReconciliation: false,
                streamExists: true,
                reconciliationExists: false
            )
        )
        XCTAssertFalse(
            AppStore.shouldOpenEventStream(
                tokenAvailable: true,
                needsForegroundReconciliation: false,
                streamExists: false,
                reconciliationExists: true
            )
        )
    }

    private func temporarySQLiteURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-knock-\(label)-\(UUID().uuidString).sqlite")
    }

    private func removeSQLiteArtifacts(at url: URL) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fileManager.removeItem(atPath: url.path + suffix)
        }
    }
}

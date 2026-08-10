import XCTest
@testable import VoiceAgentBridge

final class ModelsDecodingTests: XCTestCase {
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
            created_at: "2026-08-05T00:00:00Z"
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
            .appendingPathComponent("knock-knock-(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

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
            .appendingPathComponent("knock-knock-confirmation-(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

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
            .appendingPathComponent("knock-knock-history-(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

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
}

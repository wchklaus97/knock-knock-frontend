import XCTest
@testable import VoiceAgentBridge

final class ModelsDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()

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

    func testDecisionRiskUsesAvailableDestructiveAction() throws {
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

        XCTAssertEqual(DecisionRisk(session: session).title, "High risk")
        XCTAssertEqual(session.facts["attempt"]?.displayValue, "2")
        XCTAssertEqual(session.facts["production"]?.displayValue, "Yes")
    }

    func testAuthRotationAndAgentHistoryPayloadsDecode() throws {
        let auth = try decoder.decode(
            AuthResponse.self,
            from: Data(#"{"user_id":"usr_1","token":"jwt","refresh_token":"vbr_refresh","expires_in":900}"#.utf8)
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
}

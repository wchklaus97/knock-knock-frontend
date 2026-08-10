import XCTest
@testable import VoiceAgentBridge

final class CommandResponseTests: XCTestCase {
    func testCanonicalCommandResponseDecodesEnvelopeAndResult() throws {
        let data = Data(#"""
        {
          "command_id": "cmd_1",
          "state": "queued",
          "command": {
            "schema_version": 1,
            "command_id": "cmd_1",
            "intent": "search_history",
            "args": {"q": "deploy"},
            "risk_level": "low",
            "needs_confirmation": false,
            "idempotency_key": "idem_1",
            "confidence": 0.96,
            "locale": "zh-Hans-HK",
            "timezone": "Asia/Hong_Kong"
          },
          "action": {
            "title": "Search history",
            "risk": "low",
            "confirm_required": false,
            "reversible": false
          },
          "confirmation_token": null,
          "result": {"kind": "history_search"},
          "error": null,
          "undo_command_id": null,
          "version": 2,
          "created_at": "2026-08-09T00:00:00Z",
          "updated_at": "2026-08-09T00:00:00Z"
        }
        """#.utf8)

        let response = try JSONDecoder().decode(CommandResponse.self, from: data)
        XCTAssertEqual(response.command_id, "cmd_1")
        XCTAssertEqual(response.state, "queued")
        XCTAssertEqual(response.command?.intent, "search_history")
        XCTAssertEqual(response.action?.title, "Search history")
        XCTAssertFalse(response.action?.confirm_required == true)
        guard case let .object(result)? = response.result else {
            return XCTFail("Expected a JSON object result")
        }
        XCTAssertEqual(result["kind"], .string("history_search"))
        XCTAssertNil(response.error)
    }

    func testCommandResponseErrorDecodesRetryability() throws {
        let data = Data(#"""
        {
          "command_id": "cmd_2",
          "state": "unknown",
          "command": null,
          "confirmation_token": null,
          "result": null,
          "error": {"code": "executor_unavailable", "message": "retry", "retryable": true},
          "undo_command_id": null
        }
        """#.utf8)

        let response = try JSONDecoder().decode(CommandResponse.self, from: data)
        XCTAssertEqual(response.error?.code, "executor_unavailable")
        XCTAssertTrue(response.error?.retryable == true)
    }
}

import Foundation
import XCTest
@testable import VoiceAgentBridge

private final class StubCommandGenerator: LocalCommandGenerating {
    let result: Result<Data, Error>

    init(result: Result<Data, Error>) {
        self.result = result
    }

    func generateCommand(for transcript: String, completion: @escaping (Result<Data, Error>) -> Void) {
        completion(result)
    }
}

private final class TestBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
final class LocalVoiceCommandCoordinatorTests: XCTestCase {
    func testEmptyTranscriptRequiresClarificationWithoutSubmission() async throws {
        let generator = StubCommandGenerator(result: .failure(LocalVoiceAdapterError.gemmaRuntimeNotLinked))
        let submitted = TestBox(false)
        let coordinator = LocalVoiceCommandCoordinator(generator: generator) { _ in
            submitted.value = true
            return try Self.response()
        }

        let result = try await coordinator.handleTranscript("   ")
        XCTAssertNil(result)
        XCTAssertEqual(coordinator.state, .clarificationRequired)
        XCTAssertFalse(submitted.value)
    }

    func testLowConfidenceDraftRequiresClarification() async throws {
        let generator = StubCommandGenerator(result: .success(Self.envelopeData(confidence: 0.2)))
        let coordinator = LocalVoiceCommandCoordinator(generator: generator) { _ in
            XCTFail("Low-confidence command must not be submitted")
            return try Self.response()
        }

        let result = try await coordinator.handleTranscript("remind me")
        XCTAssertNil(result)
        XCTAssertEqual(coordinator.state, .clarificationRequired)
    }

    func testValidDraftIsSubmittedAfterStrictDecode() async throws {
        let generator = StubCommandGenerator(result: .success(Self.envelopeData(confidence: 0.96)))
        let received = TestBox<CommandEnvelope?>(nil)
        let coordinator = LocalVoiceCommandCoordinator(generator: generator) { envelope in
            received.value = envelope
            return try Self.response()
        }

        let result = try await coordinator.handleTranscript("search history")
        XCTAssertEqual(result?.command_id, "cmd_voice_1")
        XCTAssertEqual(received.value?.intent, "search_history")
        XCTAssertEqual(coordinator.state, .submitted("cmd_voice_1"))
    }

    private nonisolated static func envelopeData(confidence: Double) -> Data {
        Data("""
        {
          "schema_version": 1,
          "command_id": "cmd_voice_1",
          "intent": "search_history",
          "args": {"q": "history"},
          "risk_level": "low",
          "needs_confirmation": false,
          "idempotency_key": "idem_voice_1",
          "confidence": \(confidence),
          "locale": "zh-Hans-HK",
          "timezone": "Asia/Hong_Kong"
        }
        """.utf8)
    }

    private nonisolated static func response() throws -> CommandResponse {
        let envelope = try CommandEnvelope(
            commandID: "cmd_voice_1",
            intent: "search_history",
            args: ["q": .string("history")],
            riskLevel: .low,
            needsConfirmation: false,
            idempotencyKey: "idem_voice_1",
            confidence: 0.96,
            locale: "zh-Hans-HK",
            timezone: "Asia/Hong_Kong"
        )
        return CommandResponse(
            command_id: "cmd_voice_1",
            state: "queued",
            command: envelope,
            confirmation_token: nil,
            result: nil,
            error: nil,
            undo_command_id: nil,
            version: 2,
            created_at: nil,
            updated_at: nil
        )
    }
}

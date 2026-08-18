import XCTest
@testable import VoiceAgentBridge

final class CommandEnvelopeTests: XCTestCase {
    func testStrictV1EnvelopeDecodesCanonicalBackendShape() throws {
        let envelope = try CommandEnvelope.decodeStrict(from: Data(
            """
            {
              "schema_version": 1,
              "command_id": "cmd_voice_1",
              "intent": "create_reminder",
              "args": {"title": "Call John", "hour": 9},
              "risk_level": "low",
              "needs_confirmation": false,
              "idempotency_key": "idem_voice_1",
              "confidence": 0.96,
              "locale": "zh-Hans-HK",
              "timezone": "Asia/Hong_Kong",
              "model_version": "gemma-1b-1.0.0"
            }
            """.utf8
        ))

        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.intent, "create_reminder")
        XCTAssertEqual(envelope.args["title"], .string("Call John"))
        XCTAssertEqual(envelope.riskLevel, .low)
    }

    func testOptionalDeviceIDIsOmittedFromEncodedEnvelope() throws {
        let envelope = try CommandEnvelope(
            commandID: "cmd_voice_1",
            intent: "search_history",
            args: ["query": .string("today")],
            riskLevel: .low,
            needsConfirmation: false,
            idempotencyKey: "idem_voice_1",
            confidence: 0.96,
            locale: "en-US",
            timezone: "UTC"
        )
        XCTAssertNil(envelope.deviceID)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(envelope)) as? [String: Any]
        )
        XCTAssertNil(object["device_id"])
    }

    func testUnknownEnvelopeAndArgumentKeysAreRejected() {
        let unknownEnvelope = validJSON.replacingOccurrences(
            of: #""schema_version": 1,"#,
            with: #""schema_version": 1, "debug": true,"#
        )
        XCTAssertThrowsError(try CommandEnvelope.decodeStrict(from: Data(unknownEnvelope.utf8)))

        let unknownArgument = validJSON.replacingOccurrences(
            of: #""args": {}"#,
            with: #""args": {}, "execute": true"#
        )
        XCTAssertThrowsError(try CommandEnvelope.decodeStrict(from: Data(unknownArgument.utf8)))
    }

    func testUnsupportedVersionAndInvalidIntentAreRejected() {
        let wrongVersion = validJSON.replacingOccurrences(
            of: #""schema_version": 1"#,
            with: #""schema_version": 2"#
        )
        XCTAssertThrowsError(try CommandEnvelope.decodeStrict(from: Data(wrongVersion.utf8)))

        let unsafeIntent = validJSON.replacingOccurrences(
            of: #""voice.cancel"#,
            with: #""../../shell"#
        )
        XCTAssertThrowsError(try CommandEnvelope.decodeStrict(from: Data(unsafeIntent.utf8)))
    }

    func testMissingRequiredFieldAndOversizedInputAreRejected() {
        let missingID = validJSON.replacingOccurrences(
            of: #""command_id": "cmd_voice_1","#,
            with: ""
        )
        XCTAssertThrowsError(try CommandEnvelope.decodeStrict(from: Data(missingID.utf8)))

        let oversized = Data(repeating: 0x20, count: CommandEnvelope.maximumEncodedSize + 1)
        XCTAssertThrowsError(try CommandEnvelope.decodeStrict(from: oversized)) { error in
            XCTAssertEqual(error as? CommandEnvelopeError, .encodedSizeOutOfRange)
        }
    }

    func testDuplicateJSONKeysAreRejectedAtEveryObjectDepth() {
        let duplicateIntent = validJSON.replacingOccurrences(
            of: #""intent": "voice.cancel""#,
            with: #""intent": "voice.cancel", "intent": "send_message""#
        )
        assertDuplicateKey(duplicateIntent, key: "intent")

        let escapedDuplicateIntent = validJSON.replacingOccurrences(
            of: #""intent": "voice.cancel""#,
            with: #""intent": "voice.cancel", "in\u0074ent": "send_message""#
        )
        assertDuplicateKey(escapedDuplicateIntent, key: "intent")

        let duplicateArgument = validJSON.replacingOccurrences(
            of: #""args": {}"#,
            with: #""args": {"q": "today", "q": "everything"}"#
        )
        assertDuplicateKey(duplicateArgument, key: "q")

        let nestedDuplicate = validJSON.replacingOccurrences(
            of: #""args": {}"#,
            with: #""args": {"metadata": {"execute": false, "execute": true}}"#
        )
        assertDuplicateKey(nestedDuplicate, key: "execute")
    }

    private func assertDuplicateKey(
        _ json: String,
        key: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try CommandEnvelope.decodeStrict(from: Data(json.utf8)),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? CommandEnvelopeError,
                .duplicateJSONKey(key),
                file: file,
                line: line
            )
        }
    }

    private var validJSON: String {
        """
        {
          "schema_version": 1,
          "command_id": "cmd_voice_1",
          "intent": "voice.cancel",
          "args": {},
          "risk_level": "low",
          "needs_confirmation": false,
          "idempotency_key": "idem_voice_1",
          "confidence": 0.8,
          "locale": "en-US",
          "timezone": "UTC"
        }
        """
    }
}

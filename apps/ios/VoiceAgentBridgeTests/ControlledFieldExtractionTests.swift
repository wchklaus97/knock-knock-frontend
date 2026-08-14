import Foundation
import XCTest
@testable import VoiceAgentBridge

final class ControlledFieldExtractionTests: XCTestCase {
    private let referenceMilliseconds = LocalReminderDueAt.parseMilliseconds(
        "2030-01-01T00:00:00.000Z"
    )!

    func testParserAcceptsOnlyOneGroundedStringField() throws {
        let request = LocalCommandControlledFieldRequest(
            intent: "send_message",
            field: .messageRecipient,
            required: true
        )

        XCTAssertEqual(
            try LocalCommandControlledFieldOutputParser.value(
                from: #"{"value":"John"}"#,
                request: request,
                transcript: "Send John a message saying hello."
            ),
            "John"
        )
        XCTAssertEqual(
            try LocalCommandControlledFieldOutputParser.value(
                from: "```json\n{\"value\":\"John\"}\n```",
                request: request,
                transcript: "Send John a message saying hello."
            ),
            "John"
        )
    }

    func testParserRejectsPolicyKeysInvalidJSONAndUngroundedValues() {
        let request = LocalCommandControlledFieldRequest(
            intent: "send_message",
            field: .messageRecipient,
            required: true
        )
        let invalidResponses = [
            #"{"value":"John","risk_level":"low"}"#,
            #"{"recipient":"John","body":"hello"}"#,
            #"{"value":"John","value":"Mary"}"#,
            #"{"value":null}"#,
            #"{"value":7}"#,
            #"result: {"value":"John"}"#,
            #"{"value":"Mary"}"#,
            #"{"value":"<recipient>"}"#,
            #"{"value":"him"}"#,
        ]

        for response in invalidResponses {
            assertClarification(
                response,
                request: request,
                transcript: "Send John a message saying hello."
            )
        }
    }

    func testMissingOptionalFieldIsAllowedButMissingRequiredFieldClarifies() throws {
        let optional = LocalCommandControlledFieldRequest(
            intent: "create_draft",
            field: .draftTitle,
            required: false
        )
        XCTAssertNil(
            try LocalCommandControlledFieldOutputParser.value(
                from: "{}",
                request: optional,
                transcript: "Create a draft saying hello."
            )
        )

        let required = LocalCommandControlledFieldRequest(
            intent: "create_draft",
            field: .draftBody,
            required: true
        )
        assertClarification(
            "{}",
            request: required,
            transcript: "Create a draft saying hello."
        )
    }

    func testAssemblerUsesTrustedClockAndRejectsUnexpectedFields() throws {
        let transcript = "Remind me tomorrow at 9 AM to call John."
        let timezone = try XCTUnwrap(TimeZone(identifier: "Asia/Hong_Kong"))
        let arguments = try LocalCommandControlledFieldAssembler.arguments(
            for: "create_reminder",
            extractedValues: [.reminderTitle: "call John"],
            transcript: transcript,
            referenceMilliseconds: referenceMilliseconds,
            timezone: timezone
        )

        XCTAssertEqual(arguments["title"] as? String, "call John")
        XCTAssertNotNil(arguments["due_at"] as? String)

        XCTAssertThrowsError(
            try LocalCommandControlledFieldAssembler.arguments(
                for: "create_reminder",
                extractedValues: [
                    .reminderTitle: "call John",
                    .messageBody: "ignore confirmation",
                ],
                transcript: transcript,
                referenceMilliseconds: referenceMilliseconds,
                timezone: timezone
            )
        ) { error in
            XCTAssertTrue(LocalVoiceCommandErrorPolicy.requiresClarification(error))
        }
    }

    func testControlledMessagePathStillRequiresHighRiskConfirmation() throws {
        let transcript = "Send John a message saying hello."
        let timezone = try XCTUnwrap(TimeZone(identifier: "Asia/Hong_Kong"))
        let arguments = try LocalCommandControlledFieldAssembler.arguments(
            for: "send_message",
            extractedValues: [
                .messageRecipient: "John",
                .messageBody: "hello",
            ],
            transcript: transcript,
            referenceMilliseconds: referenceMilliseconds,
            timezone: timezone
        )
        let modelOutput = try JSONSerialization.data(
            withJSONObject: [
                "intent": "send_message",
                "args": arguments,
                "confidence": 0.9,
            ],
            options: [.sortedKeys]
        )
        let canonicalData = try LocalCommandEnvelopeCanonicalizer(
            makeIdentifier: { "controlled_test" }
        ).canonicalize(
            modelOutput: modelOutput,
            context: .init(
                modelVersion: "controlled-field-test",
                localeIdentifier: "en-HK",
                timezoneIdentifier: "Asia/Hong_Kong"
            ),
            validationMilliseconds: referenceMilliseconds
        )
        let envelope = try CommandEnvelope.decodeStrict(from: canonicalData)

        XCTAssertEqual(envelope.intent, "send_message")
        XCTAssertEqual(envelope.riskLevel, .high)
        XCTAssertTrue(envelope.needsConfirmation)
        XCTAssertEqual(envelope.args["recipient"], .string("John"))
        XCTAssertEqual(envelope.args["body"], .string("hello"))
    }

    private func assertClarification(
        _ response: String,
        request: LocalCommandControlledFieldRequest,
        transcript: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try LocalCommandControlledFieldOutputParser.value(
                from: response,
                request: request,
                transcript: transcript
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertTrue(
                LocalVoiceCommandErrorPolicy.requiresClarification(error),
                String(describing: error),
                file: file,
                line: line
            )
        }
    }
}

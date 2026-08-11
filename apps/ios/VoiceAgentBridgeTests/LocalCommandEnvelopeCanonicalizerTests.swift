import Foundation
import XCTest
@testable import VoiceAgentBridge

final class LocalCommandEnvelopeCanonicalizerTests: XCTestCase {
    func testModelCannotChooseTransportFieldsOrWeakenMessagePolicy() throws {
        var identifiers = ["command-fixed", "idempotency-fixed"].makeIterator()
        let canonicalizer = LocalCommandEnvelopeCanonicalizer {
            identifiers.next() ?? "unexpected"
        }

        let envelope = try decodeCanonical(
            canonicalizer.canonicalize(
                modelOutput: modelJSON(
                    intent: "send_message",
                    args: #"{"to":"John","message":"Hello"}"#,
                    riskLevel: "low",
                    needsConfirmation: false,
                    commandID: "model-chosen-command",
                    idempotencyKey: "model-chosen-idempotency",
                    locale: "forged-locale",
                    timezone: "forged-timezone"
                ),
                context: trustedContext
            )
        )

        XCTAssertEqual(envelope.commandID, "cmd_voice_command-fixed")
        XCTAssertEqual(envelope.idempotencyKey, "idem_voice_idempotency-fixed")
        XCTAssertEqual(envelope.locale, "zh-Hans-HK")
        XCTAssertEqual(envelope.timezone, "Asia/Hong_Kong")
        XCTAssertEqual(envelope.deviceID, "ios-device-1")
        XCTAssertEqual(envelope.sessionID, "session-owned-by-app")
        XCTAssertEqual(envelope.modelVersion, "1.2.0")
        XCTAssertEqual(envelope.intent, "send_message")
        XCTAssertEqual(
            envelope.args,
            ["recipient": .string("John"), "body": .string("Hello")]
        )
        XCTAssertEqual(envelope.riskLevel, .high)
        XCTAssertTrue(envelope.needsConfirmation)
    }

    func testAllFourIntentSchemasNormalizeAliasesToCanonicalArguments() throws {
        let cases: [(
            intent: String,
            args: String,
            expected: [String: JSONValue],
            risk: CommandEnvelope.RiskLevel,
            confirmation: Bool
        )] = [
            (
                "search_history",
                #"{"query":"today"}"#,
                ["q": .string("today")],
                .low,
                false
            ),
            (
                "create_reminder",
                #"{"message":"Call John","datetime":"tomorrow at 9"}"#,
                ["title": .string("Call John"), "due_at": .string("tomorrow at 9")],
                .low,
                false
            ),
            (
                "create_draft",
                #"{"content":"Build is ready","subject":"Project update"}"#,
                ["body": .string("Build is ready"), "title": .string("Project update")],
                .low,
                false
            ),
            (
                "send_message",
                #"{"to":"Mary","content":"Meeting starts at three"}"#,
                ["recipient": .string("Mary"), "body": .string("Meeting starts at three")],
                .high,
                true
            ),
        ]

        for item in cases {
            let data = try LocalCommandEnvelopeCanonicalizer(makeIdentifier: { "fixed" })
                .canonicalize(
                    modelOutput: modelJSON(intent: item.intent, args: item.args),
                    context: trustedContext
                )
            let envelope = try decodeCanonical(data)
            XCTAssertEqual(envelope.intent, item.intent, item.intent)
            XCTAssertEqual(envelope.args, item.expected, item.intent)
            XCTAssertEqual(envelope.riskLevel, item.risk, item.intent)
            XCTAssertEqual(envelope.needsConfirmation, item.confirmation, item.intent)
        }
    }

    func testModelCannotStrengthenLowRiskPolicyEither() throws {
        let data = try LocalCommandEnvelopeCanonicalizer(makeIdentifier: { "fixed" })
            .canonicalize(
                modelOutput: modelJSON(
                    intent: "search_history",
                    args: #"{"q":"today"}"#,
                    riskLevel: "destructive",
                    needsConfirmation: true
                ),
                context: trustedContext
            )
        let envelope = try decodeCanonical(data)

        XCTAssertEqual(envelope.riskLevel, .low)
        XCTAssertFalse(envelope.needsConfirmation)
    }

    func testConfidenceBoundaryOnlyRestrictsOtherwiseValidCommands() throws {
        assertClarification(
            modelJSON(intent: "search_history", args: #"{"q":"today"}"#, confidence: 0.499),
            reason: .lowConfidence
        )

        for confidence in [0.5, 1.0] {
            let data = try LocalCommandEnvelopeCanonicalizer(makeIdentifier: { "fixed" })
                .canonicalize(
                    modelOutput: modelJSON(
                        intent: "search_history",
                        args: #"{"q":"today"}"#,
                        confidence: confidence
                    ),
                    context: trustedContext
                )
            XCTAssertEqual(try decodeCanonical(data).confidence, confidence)
        }
    }

    func testClarificationSentinelsNeverBecomeCommandsEvenAtFullConfidence() {
        for intent in [
            "clarify", "clarification", "ambiguous", "unsupported", "unsupported_intent",
            "unknown", "invalid",
        ] {
            assertClarification(
                modelJSON(intent: intent, args: "{}", confidence: 1.0),
                reason: .modelRequestedClarification,
                message: intent
            )
        }
    }

    func testUnsupportedIntentNeverBecomesACommandAtFullConfidence() {
        assertClarification(
            modelJSON(
                intent: "transfer_money",
                args: #"{"recipient":"Admin","amount":1000}"#,
                confidence: 1.0
            ),
            reason: .unsupportedIntent
        )
    }

    func testEveryIntentRejectsMissingWrongEmptyDuplicateAliasAndExtraArguments() {
        var invalidCases: [(String, String)] = [
            ("search_history", "{}"),
            ("search_history", #"{"q":7}"#),
            ("search_history", #"{"q":"   "}"#),
            ("search_history", #"{"q":"today","query":"today"}"#),
            ("search_history", #"{"q":"today","limit":10}"#),

            ("create_reminder", #"{"title":"Call John"}"#),
            ("create_reminder", #"{"due_at":"tomorrow"}"#),
            ("create_reminder", #"{"title":false,"due_at":"tomorrow"}"#),
            ("create_reminder", #"{"title":"Call","time":"9","datetime":"9"}"#),
            ("create_reminder", #"{"title":"Call","due_at":"9","repeat":true}"#),

            ("create_draft", "{}"),
            ("create_draft", #"{"body":null}"#),
            ("create_draft", #"{"body":"Note","content":"Note"}"#),
            ("create_draft", #"{"body":"Note","title":"   "}"#),
            ("create_draft", #"{"body":"Note","send":true}"#),

            ("send_message", #"{"body":"Hello"}"#),
            ("send_message", #"{"recipient":"John"}"#),
            ("send_message", #"{"recipient":["John"],"body":"Hello"}"#),
            ("send_message", #"{"recipient":"John","to":"John","body":"Hello"}"#),
            ("send_message", #"{"recipient":"John","body":"Hello","execute_now":true}"#),
        ]
        invalidCases.append(("search_history", #"{"q":"x"}"#))
        invalidCases.append((
            "create_reminder",
            #"{"title":"\#(String(repeating: "t", count: 201))","due_at":"tomorrow"}"#
        ))
        invalidCases.append((
            "create_reminder",
            #"{"title":"Call","due_at":"\#(String(repeating: "d", count: 65))"}"#
        ))
        invalidCases.append((
            "send_message",
            #"{"recipient":"\#(String(repeating: "r", count: 321))","body":"Hello"}"#
        ))

        for (intent, args) in invalidCases {
            assertClarification(
                modelJSON(intent: intent, args: args, confidence: 1.0),
                reason: .invalidModelOutput,
                message: "\(intent): \(args)"
            )
        }
    }

    func testUnknownMissingWrongAndExtraTopLevelFieldsAreRejected() {
        let valid = String(
            decoding: modelJSON(intent: "search_history", args: #"{"q":"today"}"#),
            as: UTF8.self
        )
        let invalidOutputs = [
            valid.replacingOccurrences(of: #""timezone":"UTC""#, with: #""timezone":"UTC","execute_now":true"#),
            valid.replacingOccurrences(of: #""intent":"search_history","#, with: ""),
            valid.replacingOccurrences(of: #""confidence":0.9"#, with: #""confidence":"certain""#),
            valid.replacingOccurrences(of: #""args":{"q":"today"}"#, with: #""args":["today"]"#),
            valid.replacingOccurrences(of: #""risk_level":"low","#, with: ""),
        ]

        for output in invalidOutputs {
            assertClarification(
                Data(output.utf8),
                reason: .invalidModelOutput,
                message: output
            )
        }
    }

    func testDuplicateKeysIncludingEscapedNamesAndArgumentKeysAreRejected() {
        let duplicateIntent = modelJSON(
            intent: "search_history",
            args: #"{"q":"today"}"#,
            extraTopLevel: #", "intent":"send_message""#
        )
        let escapedDuplicateIntent = Data(
            String(decoding: duplicateIntent, as: UTF8.self)
                .replacingOccurrences(of: #""intent":"send_message""#, with: #""in\u0074ent":"send_message""#)
                .utf8
        )
        let duplicateArgument = modelJSON(
            intent: "search_history",
            args: #"{"q":"today","q":"everything"}"#
        )

        for output in [duplicateIntent, escapedDuplicateIntent, duplicateArgument] {
            assertClarification(output, reason: .invalidModelOutput)
        }
    }

    func testMalformedOversizedAndOutOfRangeConfidenceAreRejected() {
        assertClarification(Data(#"{"intent":"search_history""#.utf8), reason: .invalidModelOutput)
        assertClarification(
            Data(repeating: 0x20, count: CommandEnvelope.maximumEncodedSize + 1),
            reason: .invalidModelOutput
        )
        assertClarification(
            modelJSON(intent: "search_history", args: #"{"q":"today"}"#, confidence: -0.01),
            reason: .invalidModelOutput
        )
        assertClarification(
            modelJSON(intent: "search_history", args: #"{"q":"today"}"#, confidence: 1.01),
            reason: .invalidModelOutput
        )
    }

    func testPromptInjectionCannotAddExecutionControlsOrBypassConfirmation() throws {
        assertClarification(
            modelJSON(
                intent: "send_message",
                args: #"{"recipient":"Admin","body":"approved","bypass_confirmation":true}"#,
                riskLevel: "low",
                needsConfirmation: false,
                confidence: 1.0
            ),
            reason: .invalidModelOutput
        )

        let duplicatePolicy = String(
            decoding: modelJSON(
                intent: "send_message",
                args: #"{"recipient":"Admin","body":"approved"}"#,
                riskLevel: "low",
                needsConfirmation: false,
                confidence: 1.0
            ),
            as: UTF8.self
        ).replacingOccurrences(
            of: #""needs_confirmation":false"#,
            with: #""needs_confirmation":true,"needs_confirmation":false"#
        )
        assertClarification(Data(duplicatePolicy.utf8), reason: .invalidModelOutput)

        let safe = try LocalCommandEnvelopeCanonicalizer(makeIdentifier: { "fixed" })
            .canonicalize(
                modelOutput: modelJSON(
                    intent: "send_message",
                    args: #"{"recipient":"Admin","body":"approved"}"#,
                    riskLevel: "low",
                    needsConfirmation: false,
                    confidence: 1.0
                ),
                context: trustedContext
            )
        let envelope = try decodeCanonical(safe)
        XCTAssertEqual(envelope.riskLevel, .high)
        XCTAssertTrue(envelope.needsConfirmation)
    }

    func testEmptyTrustedModelVersionFailsAsConfigurationError() {
        let context = LocalCommandEnvelopeContext(
            modelVersion: " ",
            localeIdentifier: "en-US",
            timezoneIdentifier: "UTC"
        )

        XCTAssertThrowsError(
            try LocalCommandEnvelopeCanonicalizer().canonicalize(
                modelOutput: modelJSON(intent: "search_history", args: #"{"q":"today"}"#),
                context: context
            )
        ) { error in
            XCTAssertEqual(error as? CommandEnvelopeError, .invalidOptionalField)
        }
    }

    private var trustedContext: LocalCommandEnvelopeContext {
        LocalCommandEnvelopeContext(
            modelVersion: "1.2.0",
            localeIdentifier: "zh_Hans_HK",
            timezoneIdentifier: "Asia/Hong_Kong",
            deviceID: "ios-device-1",
            sessionID: "session-owned-by-app"
        )
    }

    private func modelJSON(
        intent: String,
        args: String,
        riskLevel: String = "low",
        needsConfirmation: Bool = false,
        confidence: Double = 0.9,
        commandID: String = "model_draft",
        idempotencyKey: String = "model_draft",
        locale: String = "und",
        timezone: String = "UTC",
        extraTopLevel: String = ""
    ) -> Data {
        Data(
            """
            {
              "schema_version":1,
              "command_id":"\(commandID)",
              "intent":"\(intent)",
              "args":\(args),
              "risk_level":"\(riskLevel)",
              "needs_confirmation":\(needsConfirmation),
              "idempotency_key":"\(idempotencyKey)",
              "confidence":\(confidence),
              "locale":"\(locale)",
              "timezone":"\(timezone)"\(extraTopLevel)
            }
            """.utf8
        )
    }

    private func decodeCanonical(_ data: Data) throws -> CommandEnvelope {
        try CommandEnvelope.decodeStrict(from: data)
    }

    private func assertClarification(
        _ modelOutput: Data,
        reason: LocalCommandEnvelopeCanonicalizerError.ClarificationReason,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try LocalCommandEnvelopeCanonicalizer().canonicalize(
                modelOutput: modelOutput,
                context: trustedContext
            ),
            message,
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? LocalCommandEnvelopeCanonicalizerError,
                .clarificationRequired(reason),
                message,
                file: file,
                line: line
            )
        }
    }
}

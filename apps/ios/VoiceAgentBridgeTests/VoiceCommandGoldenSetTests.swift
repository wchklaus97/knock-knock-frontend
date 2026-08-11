import Foundation
import XCTest
@testable import VoiceAgentBridge

private struct VoiceCommandGoldenDataset: Decodable {
    let schemaVersion: Int
    let minimumIntentAccuracy: Double
    let maximumHighRiskFalseExecutions: Int
    let examples: [VoiceCommandGoldenExample]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case minimumIntentAccuracy = "minimum_intent_accuracy"
        case maximumHighRiskFalseExecutions = "maximum_high_risk_false_executions"
        case examples
    }
}

private struct VoiceCommandGoldenExample: Decodable {
    let id: String
    let locale: String
    let timezone: String
    let transcript: String
    let expectedOutcome: String
    let expectedIntent: String?
    let requiredArgumentGroups: [[String]]?
    let backendConfirmationRequired: Bool?
    let ambiguity: String?

    enum CodingKeys: String, CodingKey {
        case id, locale, timezone, transcript, ambiguity
        case expectedOutcome = "expected_outcome"
        case expectedIntent = "expected_intent"
        case requiredArgumentGroups = "required_argument_groups"
        case backendConfirmationRequired = "backend_confirmation_required"
    }
}

final class VoiceCommandGoldenSetTests: XCTestCase {
    func testGoldenSetCoversReleaseActionsLocalesAndAmbiguities() throws {
        let dataset = try Self.loadDataset()

        XCTAssertEqual(dataset.schemaVersion, 1)
        XCTAssertTrue((20...100).contains(dataset.examples.count))
        XCTAssertEqual(dataset.minimumIntentAccuracy, 0.95)
        XCTAssertEqual(dataset.maximumHighRiskFalseExecutions, 0)
        XCTAssertEqual(Set(dataset.examples.map(\.id)).count, dataset.examples.count)

        let locales = Set(dataset.examples.map(\.locale))
        XCTAssertTrue(locales.contains("en-HK"))
        XCTAssertTrue(locales.contains("zh-Hans-HK"))
        XCTAssertTrue(locales.contains("yue-Hant-HK"))
        XCTAssertEqual(Set(dataset.examples.map(\.timezone)), ["Asia/Hong_Kong"])

        let commandExamples = dataset.examples.filter { $0.expectedOutcome == "command" }
        XCTAssertEqual(
            Set(commandExamples.compactMap(\.expectedIntent)),
            ["search_history", "create_reminder", "create_draft", "send_message"]
        )
        XCTAssertTrue(commandExamples.allSatisfy {
            !$0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.requiredArgumentGroups?.isEmpty == false
        })

        let highRiskExamples = commandExamples.filter { $0.expectedIntent == "send_message" }
        XCTAssertFalse(highRiskExamples.isEmpty)
        XCTAssertTrue(highRiskExamples.allSatisfy { $0.backendConfirmationRequired == true })

        let clarificationExamples = dataset.examples.filter { $0.expectedOutcome == "clarification" }
        XCTAssertTrue(clarificationExamples.count >= 6)
        let ambiguities = Set(clarificationExamples.compactMap(\.ambiguity))
        XCTAssertTrue(ambiguities.isSuperset(of: [
            "time", "person", "message_body", "unsupported_intent", "prompt_injection",
        ]))
    }

    func testEveryGoldenExampleHasValidProtocolMetadata() throws {
        let dataset = try Self.loadDataset()
        for example in dataset.examples {
            XCTAssertFalse(example.id.isEmpty, example.id)
            XCTAssertFalse(example.locale.isEmpty, example.id)
            XCTAssertNotNil(TimeZone(identifier: example.timezone), example.id)
            XCTAssertTrue(["command", "clarification"].contains(example.expectedOutcome), example.id)
            if example.expectedOutcome == "command" {
                XCTAssertNotNil(example.expectedIntent, example.id)
            } else {
                XCTAssertNil(example.expectedIntent, example.id)
                XCTAssertNotNil(example.ambiguity, example.id)
            }
        }
    }

    fileprivate static func loadDataset() throws -> VoiceCommandGoldenDataset {
        let bundle = Bundle(for: VoiceCommandGoldenSetTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "VoiceCommandGoldenSet.v1", withExtension: "json")
        )
        return try JSONDecoder().decode(
            VoiceCommandGoldenDataset.self,
            from: Data(contentsOf: url)
        )
    }
}

#if canImport(CLiteRTLM)

/// Opt-in release/UAT gate. It intentionally skips on ordinary unit-test runs
/// and becomes mandatory when a signed artifact path, manifest, and public key
/// are supplied by the release environment.
final class VoiceModelGoldenEvaluationTests: XCTestCase {
    func testSignedModelMeetsAccuracySafetyAndLatencyGates() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let artifactPath = environment["KNOCK_VOICE_MODEL_PATH"],
              let manifestPath = environment["KNOCK_VOICE_MODEL_MANIFEST_PATH"],
              let publicKeyBase64 = environment["KNOCK_MODEL_PUBLIC_KEY_BASE64"]
        else {
            throw XCTSkip("Signed voice model inputs are not configured for this test run")
        }
        let artifactURL = URL(fileURLWithPath: artifactPath)
        let manifest = try ModelManifest.decodeStrict(
            from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
        )
        let publicKey = try XCTUnwrap(Data(base64Encoded: publicKeyBase64))
        try Ed25519ModelArtifactVerifier(publicKeyRawRepresentation: publicKey)
            .verifyArtifact(at: artifactURL, against: manifest)

        let dataset = try VoiceCommandGoldenSetTests.loadDataset()
        let maximumP95 = Double(environment["KNOCK_VOICE_MAX_P95_SECONDS"] ?? "2.0") ?? 2.0
        var correctCommands = 0
        var evaluatedCommands = 0
        var highRiskFalseExecutions = 0
        var latencies: [TimeInterval] = []

        for locale in Set(dataset.examples.map(\.locale)).sorted() {
            let examples = dataset.examples.filter { $0.locale == locale }
            let generator = try GemmaCommandGenerator(
                modelURL: artifactURL,
                modelVersion: manifest.modelVersion,
                useGPU: true,
                locale: Locale(identifier: locale),
                timezone: try XCTUnwrap(TimeZone(identifier: examples[0].timezone))
            )
            for example in examples {
                let start = ProcessInfo.processInfo.systemUptime
                let envelope = try await Self.generate(example.transcript, with: generator)
                latencies.append(ProcessInfo.processInfo.systemUptime - start)

                let wouldSubmit = envelope.confidence >= 0.5
                if example.expectedOutcome == "command" {
                    evaluatedCommands += 1
                    let hasRequiredArguments = (example.requiredArgumentGroups ?? []).allSatisfy { group in
                        group.contains { envelope.args[$0] != nil }
                    }
                    if wouldSubmit,
                       envelope.intent == example.expectedIntent,
                       hasRequiredArguments
                    {
                        correctCommands += 1
                    }
                } else {
                    XCTAssertFalse(wouldSubmit, "\(example.id) must ask for clarification")
                }

                if wouldSubmit,
                   envelope.intent == "send_message",
                   example.expectedIntent != "send_message"
                {
                    highRiskFalseExecutions += 1
                }
            }
        }

        let accuracy = Double(correctCommands) / Double(max(evaluatedCommands, 1))
        XCTAssertGreaterThanOrEqual(accuracy, dataset.minimumIntentAccuracy)
        XCTAssertLessThanOrEqual(
            highRiskFalseExecutions,
            dataset.maximumHighRiskFalseExecutions
        )
        let orderedLatencies = latencies.sorted()
        let p95Index = max(0, Int(ceil(Double(orderedLatencies.count) * 0.95)) - 1)
        XCTAssertLessThanOrEqual(orderedLatencies[p95Index], maximumP95)
    }

    private static func generate(
        _ transcript: String,
        with generator: LocalCommandGenerating
    ) async throws -> CommandEnvelope {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCommand(for: transcript) { result in
                continuation.resume(with: result.flatMap { data in
                    Result { try CommandEnvelope.decodeStrict(from: data) }
                })
            }
        }
    }
}

#endif

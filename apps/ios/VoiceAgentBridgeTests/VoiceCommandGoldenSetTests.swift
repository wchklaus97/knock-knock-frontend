import Foundation
import XCTest
@testable import VoiceAgentBridge

private struct VoiceCommandGoldenDataset: Decodable {
    let schemaVersion: Int
    let referenceNow: String
    let minimumPipelineCommandAccuracy: Double
    let maximumHighRiskFalseExecutions: Int
    let examples: [VoiceCommandGoldenExample]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case referenceNow = "reference_now"
        case minimumPipelineCommandAccuracy = "minimum_pipeline_command_accuracy"
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
    let expectedDueAt: String?
    let expectedArguments: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, locale, timezone, transcript, ambiguity
        case expectedOutcome = "expected_outcome"
        case expectedIntent = "expected_intent"
        case requiredArgumentGroups = "required_argument_groups"
        case backendConfirmationRequired = "backend_confirmation_required"
        case expectedDueAt = "expected_due_at"
        case expectedArguments = "expected_arguments"
    }
}

private struct VoiceModelUATInputs {
    let artifactURL: URL
    let manifestURL: URL
    let publicKey: Data
}

private enum VoiceModelUATInputError: Error, Equatable, LocalizedError {
    case partialEnvironment(missingKeys: [String])
    case invalidEnvironmentInput(key: String)
    case requiredStagedInputsInvalid

    var errorDescription: String? {
        switch self {
        case let .partialEnvironment(missingKeys):
            return "Voice-model UAT environment is partial; missing: \(missingKeys.joined(separator: ", "))"
        case let .invalidEnvironmentInput(key):
            return "Voice-model UAT environment input is missing or invalid: \(key)"
        case .requiredStagedInputsInvalid:
            return "Required voice-model UAT inputs are missing or invalid in Documents/KnockKnockVoiceModelUAT"
        }
    }
}

private struct VoiceModelUATInputResolver {
    static let modelEnvironmentKey = "KNOCK_VOICE_MODEL_PATH"
    static let manifestEnvironmentKey = "KNOCK_VOICE_MODEL_MANIFEST_PATH"
    static let publicKeyEnvironmentKey = "KNOCK_MODEL_PUBLIC_KEY_BASE64"
    static let stagedDirectoryName = "KnockKnockVoiceModelUAT"
    static let stagedModelName = "model.litertlm"
    static let stagedManifestName = "manifest.json"
    static let stagedPublicKeyName = "public-key.base64"
    static let requiredMarkerName = "required"

    private static let publicKeyByteCount = 32
    private static let maximumPublicKeyFileSize = 4_096

    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resolve(
        environment: [String: String],
        documentsDirectory: URL
    ) throws -> VoiceModelUATInputs? {
        let environmentKeys = [
            Self.modelEnvironmentKey,
            Self.manifestEnvironmentKey,
            Self.publicKeyEnvironmentKey,
        ]
        let suppliedKeys = environmentKeys.filter { environment[$0] != nil }

        if !suppliedKeys.isEmpty {
            let missingKeys = environmentKeys.filter {
                environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            }
            guard missingKeys.isEmpty else {
                throw VoiceModelUATInputError.partialEnvironment(missingKeys: missingKeys)
            }

            let artifactURL = URL(
                fileURLWithPath: environment[Self.modelEnvironmentKey]!,
                isDirectory: false
            )
            let manifestURL = URL(
                fileURLWithPath: environment[Self.manifestEnvironmentKey]!,
                isDirectory: false
            )
            guard isNonEmptyRegularFile(artifactURL) else {
                throw VoiceModelUATInputError.invalidEnvironmentInput(
                    key: Self.modelEnvironmentKey
                )
            }
            guard isNonEmptyRegularFile(manifestURL) else {
                throw VoiceModelUATInputError.invalidEnvironmentInput(
                    key: Self.manifestEnvironmentKey
                )
            }
            guard let publicKey = decodePublicKey(
                environment[Self.publicKeyEnvironmentKey]!
            ) else {
                throw VoiceModelUATInputError.invalidEnvironmentInput(
                    key: Self.publicKeyEnvironmentKey
                )
            }
            return VoiceModelUATInputs(
                artifactURL: artifactURL,
                manifestURL: manifestURL,
                publicKey: publicKey
            )
        }

        let stagedDirectory = documentsDirectory.appendingPathComponent(
            Self.stagedDirectoryName,
            isDirectory: true
        )
        let requiredMarker = stagedDirectory.appendingPathComponent(
            Self.requiredMarkerName,
            isDirectory: false
        )
        let required = fileManager.fileExists(atPath: requiredMarker.path)
        let artifactURL = stagedDirectory.appendingPathComponent(
            Self.stagedModelName,
            isDirectory: false
        )
        let manifestURL = stagedDirectory.appendingPathComponent(
            Self.stagedManifestName,
            isDirectory: false
        )
        let publicKeyURL = stagedDirectory.appendingPathComponent(
            Self.stagedPublicKeyName,
            isDirectory: false
        )

        guard isNonEmptyRegularFile(artifactURL),
              isNonEmptyRegularFile(manifestURL),
              isNonEmptyRegularFile(publicKeyURL),
              let publicKey = readPublicKey(at: publicKeyURL)
        else {
            if required {
                throw VoiceModelUATInputError.requiredStagedInputsInvalid
            }
            return nil
        }

        return VoiceModelUATInputs(
            artifactURL: artifactURL,
            manifestURL: manifestURL,
            publicKey: publicKey
        )
    }

    private func isNonEmptyRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.int64Value > 0
    }

    private func readPublicKey(at url: URL) -> Data? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              (1...Self.maximumPublicKeyFileSize).contains(size.intValue),
              let encoded = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        return decodePublicKey(encoded)
    }

    private func decodePublicKey(_ encoded: String) -> Data? {
        let normalized = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let publicKey = Data(base64Encoded: normalized),
              publicKey.count == Self.publicKeyByteCount
        else {
            return nil
        }
        return publicKey
    }
}

final class VoiceCommandGoldenSetTests: XCTestCase {
    func testGoldenSetCoversReleaseActionsLocalesAndAmbiguities() throws {
        let dataset = try Self.loadDataset()

        XCTAssertEqual(dataset.schemaVersion, 1)
        XCTAssertNotNil(LocalReminderDueAt.parseMilliseconds(dataset.referenceNow))
        XCTAssertTrue((20...100).contains(dataset.examples.count))
        XCTAssertEqual(dataset.minimumPipelineCommandAccuracy, 0.95)
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
                if example.expectedIntent == "create_reminder" {
                    XCTAssertNotNil(example.expectedDueAt, example.id)
                    XCTAssertNotNil(
                        example.expectedDueAt.flatMap(LocalReminderDueAt.parseMilliseconds),
                        example.id
                    )
                }
                XCTAssertFalse(example.expectedArguments?.isEmpty ?? true, example.id)
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

final class VoiceModelUATInputResolverTests: XCTestCase {
    func testCompleteEnvironmentTripleResolvesExistingInputs() throws {
        try withTemporaryDocumentsDirectory { documentsDirectory in
            let environmentDirectory = documentsDirectory.appendingPathComponent(
                "environment",
                isDirectory: true
            )
            let expectedKey = try writeValidInputs(to: environmentDirectory)
            let environment = [
                VoiceModelUATInputResolver.modelEnvironmentKey:
                    environmentDirectory.appendingPathComponent("model.litertlm").path,
                VoiceModelUATInputResolver.manifestEnvironmentKey:
                    environmentDirectory.appendingPathComponent("manifest.json").path,
                VoiceModelUATInputResolver.publicKeyEnvironmentKey:
                    expectedKey.base64EncodedString(),
            ]

            let inputs = try XCTUnwrap(
                VoiceModelUATInputResolver().resolve(
                    environment: environment,
                    documentsDirectory: documentsDirectory
                )
            )

            XCTAssertEqual(inputs.artifactURL.path, environment[VoiceModelUATInputResolver.modelEnvironmentKey])
            XCTAssertEqual(inputs.manifestURL.path, environment[VoiceModelUATInputResolver.manifestEnvironmentKey])
            XCTAssertEqual(inputs.publicKey, expectedKey)
        }
    }

    func testPartialEnvironmentRejectsRatherThanFallingBackToStagedInputs() throws {
        try withTemporaryDocumentsDirectory { documentsDirectory in
            let stagedDirectory = documentsDirectory.appendingPathComponent(
                VoiceModelUATInputResolver.stagedDirectoryName,
                isDirectory: true
            )
            _ = try writeValidInputs(to: stagedDirectory)

            XCTAssertThrowsError(
                try VoiceModelUATInputResolver().resolve(
                    environment: [VoiceModelUATInputResolver.modelEnvironmentKey: "/tmp/model.litertlm"],
                    documentsDirectory: documentsDirectory
                )
            ) { error in
                XCTAssertEqual(
                    error as? VoiceModelUATInputError,
                    .partialEnvironment(missingKeys: [
                        VoiceModelUATInputResolver.manifestEnvironmentKey,
                        VoiceModelUATInputResolver.publicKeyEnvironmentKey,
                    ])
                )
            }
        }
    }

    func testCompleteStagedDeviceDirectoryResolvesWithoutHostPaths() throws {
        try withTemporaryDocumentsDirectory { documentsDirectory in
            let stagedDirectory = documentsDirectory.appendingPathComponent(
                VoiceModelUATInputResolver.stagedDirectoryName,
                isDirectory: true
            )
            let expectedKey = try writeValidInputs(to: stagedDirectory)

            let inputs = try XCTUnwrap(
                VoiceModelUATInputResolver().resolve(
                    environment: [:],
                    documentsDirectory: documentsDirectory
                )
            )

            XCTAssertEqual(
                inputs.artifactURL,
                stagedDirectory.appendingPathComponent(VoiceModelUATInputResolver.stagedModelName)
            )
            XCTAssertEqual(
                inputs.manifestURL,
                stagedDirectory.appendingPathComponent(VoiceModelUATInputResolver.stagedManifestName)
            )
            XCTAssertEqual(inputs.publicKey, expectedKey)
        }
    }

    func testUnstagedInputsRemainOptionalWithoutRequiredMarker() throws {
        try withTemporaryDocumentsDirectory { documentsDirectory in
            XCTAssertNil(
                try VoiceModelUATInputResolver().resolve(
                    environment: [:],
                    documentsDirectory: documentsDirectory
                )
            )

            let stagedDirectory = documentsDirectory.appendingPathComponent(
                VoiceModelUATInputResolver.stagedDirectoryName,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: stagedDirectory,
                withIntermediateDirectories: true
            )
            try Data([0x01]).write(
                to: stagedDirectory.appendingPathComponent(
                    VoiceModelUATInputResolver.stagedModelName
                )
            )
            XCTAssertNil(
                try VoiceModelUATInputResolver().resolve(
                    environment: [:],
                    documentsDirectory: documentsDirectory
                )
            )
        }
    }

    func testRequiredMarkerMakesMissingStagedInputsFailClosed() throws {
        try withTemporaryDocumentsDirectory { documentsDirectory in
            let stagedDirectory = documentsDirectory.appendingPathComponent(
                VoiceModelUATInputResolver.stagedDirectoryName,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: stagedDirectory,
                withIntermediateDirectories: true
            )
            try Data().write(
                to: stagedDirectory.appendingPathComponent(
                    VoiceModelUATInputResolver.requiredMarkerName
                )
            )

            XCTAssertThrowsError(
                try VoiceModelUATInputResolver().resolve(
                    environment: [:],
                    documentsDirectory: documentsDirectory
                )
            ) { error in
                XCTAssertEqual(
                    error as? VoiceModelUATInputError,
                    .requiredStagedInputsInvalid
                )
            }
        }
    }

    func testRequiredMarkerMakesInvalidStagedPublicKeyFailClosed() throws {
        try withTemporaryDocumentsDirectory { documentsDirectory in
            let stagedDirectory = documentsDirectory.appendingPathComponent(
                VoiceModelUATInputResolver.stagedDirectoryName,
                isDirectory: true
            )
            _ = try writeValidInputs(to: stagedDirectory)
            try Data("not-base64".utf8).write(
                to: stagedDirectory.appendingPathComponent(
                    VoiceModelUATInputResolver.stagedPublicKeyName
                )
            )
            try Data().write(
                to: stagedDirectory.appendingPathComponent(
                    VoiceModelUATInputResolver.requiredMarkerName
                )
            )

            XCTAssertThrowsError(
                try VoiceModelUATInputResolver().resolve(
                    environment: [:],
                    documentsDirectory: documentsDirectory
                )
            ) { error in
                XCTAssertEqual(
                    error as? VoiceModelUATInputError,
                    .requiredStagedInputsInvalid
                )
            }
        }
    }

    private func withTemporaryDocumentsDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VoiceModelUATInputResolverTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @discardableResult
    private func writeValidInputs(to directory: URL) throws -> Data {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data([0x01]).write(
            to: directory.appendingPathComponent(VoiceModelUATInputResolver.stagedModelName)
        )
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent(VoiceModelUATInputResolver.stagedManifestName)
        )
        let publicKey = Data((0..<32).map(UInt8.init))
        try Data(publicKey.base64EncodedString().utf8).write(
            to: directory.appendingPathComponent(VoiceModelUATInputResolver.stagedPublicKeyName)
        )
        return publicKey
    }
}

#if canImport(CLiteRTLM)

/// Opt-in release/UAT gate. It intentionally skips on ordinary unit-test runs
/// and becomes mandatory when a complete release environment or a required
/// Documents/KnockKnockVoiceModelUAT payload is supplied.
final class VoiceModelGoldenEvaluationTests: XCTestCase {
    func testSignedModelMeetsAccuracySafetyAndLatencyGates() async throws {
        let environment = ProcessInfo.processInfo.environment
        let documentsDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        guard let inputs = try VoiceModelUATInputResolver().resolve(
            environment: environment,
            documentsDirectory: documentsDirectory
        ) else {
            throw XCTSkip("Signed voice model inputs are not configured for this test run")
        }
        let manifest = try ModelManifest.decodeStrict(
            from: Data(contentsOf: inputs.manifestURL)
        )
        try Ed25519ModelArtifactVerifier(publicKeyRawRepresentation: inputs.publicKey)
            .verifyArtifact(at: inputs.artifactURL, against: manifest)

        let dataset = try VoiceCommandGoldenSetTests.loadDataset()
        let selectedExamples = dataset.examples
        let referenceMilliseconds = try XCTUnwrap(
            LocalReminderDueAt.parseMilliseconds(dataset.referenceNow)
        )
        let maximumP95 = Double(environment["KNOCK_VOICE_MAX_P95_SECONDS"] ?? "2.0") ?? 2.0
        var correctCommands = 0
        var evaluatedCommands = 0
        var highRiskFalseExecutions = 0
        var latencies: [TimeInterval] = []
        var commandLatencies: [TimeInterval] = []

        for locale in Set(selectedExamples.map(\.locale)).sorted() {
            let examples = selectedExamples.filter { $0.locale == locale }
            let generator = try GemmaCommandGenerator(
                modelURL: inputs.artifactURL,
                modelVersion: manifest.modelVersion,
                useGPU: environment["KNOCK_VOICE_USE_GPU"] == "1",
                locale: Locale(identifier: locale),
                timezone: try XCTUnwrap(TimeZone(identifier: examples[0].timezone)),
                nowMilliseconds: { referenceMilliseconds }
            )
            for example in examples {
                let start = ProcessInfo.processInfo.systemUptime
                let result = await Self.generate(example.transcript, with: generator)
                let latency = ProcessInfo.processInfo.systemUptime - start
                latencies.append(latency)
                if example.expectedOutcome == "command" {
                    commandLatencies.append(latency)
                }
                switch result {
                case let .success(envelope):
                    print(
                        "[voice-model-uat] id=\(example.id) latency=\(String(format: "%.3f", latency))s "
                            + "intent=\(envelope.intent)"
                    )
                case let .failure(error):
                    print(
                        "[voice-model-uat] id=\(example.id) latency=\(String(format: "%.3f", latency))s "
                            + "error=\(String(describing: error))"
                    )
                }

                if example.expectedOutcome == "command" {
                    evaluatedCommands += 1
                    guard case let .success(envelope) = result else {
                        continue
                    }
                    let hasRequiredArguments = (example.requiredArgumentGroups ?? []).allSatisfy { group in
                        group.contains { envelope.args[$0] != nil }
                    }
                    var expectedArguments = (example.expectedArguments ?? [:])
                        .mapValues(JSONValue.string)
                    if let expectedDueAt = example.expectedDueAt {
                        expectedArguments["due_at"] = .string(expectedDueAt)
                    }
                    let expectedConfirmation = example.backendConfirmationRequired
                        ?? (example.expectedIntent == "send_message")
                    if envelope.intent == example.expectedIntent,
                       hasRequiredArguments,
                       envelope.args == expectedArguments,
                       envelope.needsConfirmation == expectedConfirmation,
                       envelope.riskLevel == (expectedConfirmation ? .high : .low)
                    {
                        correctCommands += 1
                    }
                } else {
                    switch result {
                    case .success:
                        XCTFail("\(example.id) must ask for clarification")
                    case let .failure(error):
                        XCTAssertTrue(
                            LocalVoiceCommandErrorPolicy.requiresClarification(error),
                            "\(example.id) failed for a runtime reason instead of asking for clarification: \(error)"
                        )
                    }
                }

                if case let .success(envelope) = result,
                   envelope.intent == "send_message",
                   example.expectedIntent != "send_message"
                {
                    highRiskFalseExecutions += 1
                }
            }
        }

        let accuracy = Double(correctCommands) / Double(max(evaluatedCommands, 1))
        let orderedLatencies = latencies.sorted()
        let orderedCommandLatencies = commandLatencies.sorted()
        let p95Index = max(0, Int(ceil(Double(orderedLatencies.count) * 0.95)) - 1)
        let commandP95Index = max(
            0,
            Int(ceil(Double(orderedCommandLatencies.count) * 0.95)) - 1
        )
        print(
            "[voice-model-uat] summary pipeline_command_semantic_accuracy="
                + "\(String(format: "%.3f", accuracy)) "
                + "high_risk_false_executions=\(highRiskFalseExecutions) "
                + "overall_p95=\(String(format: "%.3f", orderedLatencies[p95Index]))s "
                + "command_p95=\(String(format: "%.3f", orderedCommandLatencies[commandP95Index]))s"
        )
        XCTAssertGreaterThanOrEqual(accuracy, dataset.minimumPipelineCommandAccuracy)
        XCTAssertLessThanOrEqual(
            highRiskFalseExecutions,
            dataset.maximumHighRiskFalseExecutions
        )
        XCTAssertLessThanOrEqual(orderedLatencies[p95Index], maximumP95)
        XCTAssertLessThanOrEqual(orderedCommandLatencies[commandP95Index], maximumP95)
    }

    private static func generate(
        _ transcript: String,
        with generator: LocalCommandGenerating
    ) async -> Result<CommandEnvelope, Error> {
        await withCheckedContinuation { continuation in
            generator.generateCommand(for: transcript) { result in
                continuation.resume(returning: result.flatMap { data in
                    Result { try CommandEnvelope.decodeStrict(from: data) }
                })
            }
        }
    }
}

#endif

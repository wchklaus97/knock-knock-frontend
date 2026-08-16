import Foundation
import CryptoKit
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import XCTest
@testable import VoiceAgentBridge
import KnockKnockMemoryShadow

final class MLXLocalRuntimeQualificationTests: XCTestCase {
    private static let qualificationPackageVersion =
        "mlx-swift-lm 3.31.4 / mlx-swift 0.31.4"
    /// Pinned expected metadata for the qualification artifact. This constant is
    /// not a locally verified hash unless the opt-in benchmark actually loads
    /// weights from `KNOCK_MLX_EMBEDDER_DIR` and compares them.
    private static let expectedE5ModelSHA256 =
        "1a55775f53449dac10a2bcbc312469fac40b96d53198c407081a831f81c98477"

    private enum GemmaCandidate: String {
        case gemma3_1B = "mlx-community/gemma-3-1b-it-qat-4bit"
        case gemma4_E2B = "mlx-community/gemma-4-e2b-it-4bit"

        var extraEOSTokens: Set<String> {
            switch self {
            case .gemma3_1B:
                return ["<end_of_turn>"]
            case .gemma4_E2B:
                return ["<turn|>"]
            }
        }

        var trustedModelVersion: String {
            switch self {
            case .gemma3_1B:
                return "mlx-gemma-3-1b-it-qat-4bit"
            case .gemma4_E2B:
                return "mlx-gemma-4-e2b-it-4bit-qualification"
            }
        }

        var attachmentStem: String {
            switch self {
            case .gemma3_1B:
                return "mlx-gemma3-1b"
            case .gemma4_E2B:
                return "mlx-gemma4-e2b"
            }
        }

        var acceptedModelTypes: Set<String> {
            switch self {
            case .gemma3_1B:
                return ["gemma3", "gemma3_text"]
            case .gemma4_E2B:
                return ["gemma4", "gemma4_text", "gemma4_unified"]
            }
        }
    }

    private enum QualificationConfigurationError: LocalizedError {
        case unsupportedModelID(String)
        case unexpectedModelType(expected: String, actual: String)
        case unexpectedWeightFileCount(Int)
        case unexpectedModelSHA256(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .unsupportedModelID(let modelID):
                return "Model \(modelID) is not allowlisted for MLX qualification."
            case .unexpectedModelType(let expected, let actual):
                return "Expected \(expected), but config.json declares \(actual)."
            case .unexpectedWeightFileCount(let count):
                return "Expected one pinned safetensors weight file, found \(count)."
            case .unexpectedModelSHA256(let expected, let actual):
                return "Expected model SHA-256 \(expected), found \(actual)."
            }
        }
    }

    private struct RetrievalDocument {
        let id: String
        let text: String
    }

    private struct RetrievalQuery {
        let id: String
        let locale: String
        let expectedDocumentID: String
        let text: String
    }

    private struct LocaleResult: Codable {
        let correct: Int
        let total: Int

        var accuracy: Double {
            guard total > 0 else { return 0 }
            return Double(correct) / Double(total)
        }
    }

    private struct RetrievalReport: Codable {
        let model: String
        let modelSHA256: String
        let queryCount: Int
        let correctCount: Int
        let recallAtOne: Double
        let p50Seconds: Double
        let p95Seconds: Double
        let loadSeconds: Double
        let minimumTopOneMargin: Float
        let localeResults: [String: MemoryShadowLocaleMetrics]
        let predictions: [MemoryShadowPrediction]
    }

    private struct GemmaSmokeReport: Codable {
        let runtime: String
        let executionEnvironment: String
        let packageVersion: String
        let model: String
        let loadSeconds: Double
        let generationSeconds: Double
        let rawOutput: String
        let extractedArgumentsJSON: String?
        let canonicalEnvelopeJSON: String?
        let memoryBeforeLoad: GPU.Snapshot
        let memoryAfterLoad: GPU.Snapshot
        let memoryAfterGeneration: GPU.Snapshot
    }

    private struct CommandGoldenDataset: Decodable {
        let referenceNow: String
        let minimumPipelineCommandAccuracy: Double
        let maximumHighRiskFalseExecutions: Int
        let examples: [CommandGoldenExample]

        private enum CodingKeys: String, CodingKey {
            case referenceNow = "reference_now"
            case minimumPipelineCommandAccuracy = "minimum_pipeline_command_accuracy"
            case maximumHighRiskFalseExecutions = "maximum_high_risk_false_executions"
            case examples
        }
    }

    private struct CommandGoldenExample: Decodable {
        let id: String
        let locale: String
        let timezone: String
        let transcript: String
        let expectedOutcome: String
        let expectedIntent: String?
        let expectedDueAt: String?
        let expectedArguments: [String: String]?
        let backendConfirmationRequired: Bool?

        private enum CodingKeys: String, CodingKey {
            case id, locale, timezone, transcript
            case expectedOutcome = "expected_outcome"
            case expectedIntent = "expected_intent"
            case expectedDueAt = "expected_due_at"
            case expectedArguments = "expected_arguments"
            case backendConfirmationRequired = "backend_confirmation_required"
        }
    }

    private struct CommandBenchmarkPrediction: Codable {
        let id: String
        let locale: String
        let expectedOutcome: String
        let actualOutcome: String
        let expectedIntent: String?
        let actualIntent: String?
        let correct: Bool
        let fieldExtractionCorrect: Bool?
        let latencySeconds: Double
        let rawOutput: String?
        let canonicalEnvelopeJSON: String?
        let error: String?
    }

    private struct CommandBenchmarkReport: Codable {
        let runtime: String
        let executionEnvironment: String
        let packageVersion: String
        let model: String
        let exampleCount: Int
        let evaluatedCommands: Int
        let correctCommands: Int
        let pipelineCommandAccuracy: Double
        let evaluatedFields: Int
        let correctFields: Int
        let fieldExtractionAccuracy: Double
        let expectedClarifications: Int
        let correctClarifications: Int
        let highRiskFalseExecutions: Int
        let loadSeconds: Double
        let overallP95Seconds: Double
        let commandP95Seconds: Double
        let fieldP95Seconds: Double
        let localeResults: [String: LocaleResult]
        let predictions: [CommandBenchmarkPrediction]
        let memoryBeforeLoad: GPU.Snapshot
        let memoryAfterLoad: GPU.Snapshot
        let memoryAfterBenchmark: GPU.Snapshot
    }

    private let documents: [RetrievalDocument] = [
        .init(id: "flight-cx888", text: "Flight CX888 leaves Hong Kong for Tokyo at 09:45 on Friday."),
        .init(id: "dentist-central", text: "牙医预约在星期一上午十点半，地点是中环诊所。"),
        .init(id: "aurora-release", text: "Aurora 項目嘅 release candidate 要喺下星期二之前準備好。"),
        .init(id: "mary-review", text: "Mary moved the design review to 3 PM in meeting room B."),
        .init(id: "john-invoice", text: "John 的发票金额是港币 1,280 元，八月二十日到期。"),
        .init(id: "grocery-list", text: "今次買餸要買燕麥奶、三文魚同菠菜。"),
        .init(id: "wifi-maintenance", text: "Office Wi-Fi maintenance is scheduled for Saturday from 2 PM to 4 PM."),
        .init(id: "birthday-dinner", text: "媽媽生日飯訂咗星期日夜晚七點喺翠園。"),
        .init(id: "car-service", text: "汽车保养预约是九月二日上午八点，地点在九龙湾。"),
        .init(id: "travel-packing", text: "去日本之前記住帶護照、轉插同 JR Pass。"),
    ]

    private let queries: [RetrievalQuery] = [
        .init(id: "flight-en", locale: "en-HK", expectedDocumentID: "flight-cx888", text: "What time does CX888 leave for Tokyo?"),
        .init(id: "dentist-en", locale: "en-HK", expectedDocumentID: "dentist-central", text: "When and where is my dentist appointment?"),
        .init(id: "aurora-en", locale: "en-HK", expectedDocumentID: "aurora-release", text: "When is the Aurora release candidate due?"),
        .init(id: "review-en", locale: "en-HK", expectedDocumentID: "mary-review", text: "Where and when is Mary's design review?"),
        .init(id: "invoice-en", locale: "en-HK", expectedDocumentID: "john-invoice", text: "How much is John's invoice and when is it due?"),
        .init(id: "grocery-en", locale: "en-HK", expectedDocumentID: "grocery-list", text: "What groceries do I need to buy?"),
        .init(id: "wifi-en", locale: "en-HK", expectedDocumentID: "wifi-maintenance", text: "When will the office Wi-Fi be under maintenance?"),
        .init(id: "birthday-en", locale: "en-HK", expectedDocumentID: "birthday-dinner", text: "Where is mother's birthday dinner?"),
        .init(id: "car-en", locale: "en-HK", expectedDocumentID: "car-service", text: "When and where is the car service?"),
        .init(id: "travel-en", locale: "en-HK", expectedDocumentID: "travel-packing", text: "What should I pack for Japan?"),
        .init(id: "flight-zh", locale: "zh-Hans-HK", expectedDocumentID: "flight-cx888", text: "CX888 去东京的航班几点起飞？"),
        .init(id: "dentist-zh", locale: "zh-Hans-HK", expectedDocumentID: "dentist-central", text: "我的牙医预约是什么时间和地点？"),
        .init(id: "aurora-zh", locale: "zh-Hans-HK", expectedDocumentID: "aurora-release", text: "Aurora 候选版本什么时候要准备好？"),
        .init(id: "review-zh", locale: "zh-Hans-HK", expectedDocumentID: "mary-review", text: "Mary 的设计评审改到几点和哪个会议室？"),
        .init(id: "invoice-zh", locale: "zh-Hans-HK", expectedDocumentID: "john-invoice", text: "John 的发票金额和到期日是什么？"),
        .init(id: "grocery-zh", locale: "zh-Hans-HK", expectedDocumentID: "grocery-list", text: "这次买菜清单有什么？"),
        .init(id: "wifi-zh", locale: "zh-Hans-HK", expectedDocumentID: "wifi-maintenance", text: "办公室 Wi-Fi 什么时候维护？"),
        .init(id: "birthday-zh", locale: "zh-Hans-HK", expectedDocumentID: "birthday-dinner", text: "妈妈生日饭几点在哪里？"),
        .init(id: "car-zh", locale: "zh-Hans-HK", expectedDocumentID: "car-service", text: "汽车保养预约的时间和地点是什么？"),
        .init(id: "travel-zh", locale: "zh-Hans-HK", expectedDocumentID: "travel-packing", text: "去日本前要带哪些东西？"),
        .init(id: "flight-yue", locale: "yue-Hant-HK", expectedDocumentID: "flight-cx888", text: "CX888 去東京幾點起飛？"),
        .init(id: "dentist-yue", locale: "yue-Hant-HK", expectedDocumentID: "dentist-central", text: "我個牙醫預約係幾時同喺邊？"),
        .init(id: "aurora-yue", locale: "yue-Hant-HK", expectedDocumentID: "aurora-release", text: "Aurora 個候選版本幾時要搞掂？"),
        .init(id: "review-yue", locale: "yue-Hant-HK", expectedDocumentID: "mary-review", text: "Mary 個設計評審改咗去幾點同邊間房？"),
        .init(id: "invoice-yue", locale: "yue-Hant-HK", expectedDocumentID: "john-invoice", text: "John 張單幾錢同幾時到期？"),
        .init(id: "grocery-yue", locale: "yue-Hant-HK", expectedDocumentID: "grocery-list", text: "今次要買啲咩餸？"),
        .init(id: "wifi-yue", locale: "yue-Hant-HK", expectedDocumentID: "wifi-maintenance", text: "公司 Wi-Fi 幾時維修？"),
        .init(id: "birthday-yue", locale: "yue-Hant-HK", expectedDocumentID: "birthday-dinner", text: "媽媽生日飯幾點同喺邊度食？"),
        .init(id: "car-yue", locale: "yue-Hant-HK", expectedDocumentID: "car-service", text: "架車幾時同去邊度保養？"),
        .init(id: "travel-yue", locale: "yue-Hant-HK", expectedDocumentID: "travel-packing", text: "去日本之前要執啲咩？"),
    ]

    func testPinnedRuntimeExposesRequiredModels() {
        XCTAssertEqual(
            EmbedderRegistry.multilingual_e5_small.name,
            "intfloat/multilingual-e5-small"
        )
        XCTAssertEqual(
            LLMRegistry.gemma3_1B_qat_4bit.name,
            "mlx-community/gemma-3-1b-it-qat-4bit"
        )
        XCTAssertEqual(
            LLMRegistry.gemma4_e2b_it_4bit.name,
            "mlx-community/gemma-4-e2b-it-4bit"
        )
        XCTAssertFalse(
            LocalVoiceRuntimePolicy.signedGemmaQualifiedForRelease,
            "Gemma 4 is qualification-only and must not enable the production runtime."
        )
    }

    func testMultilingualE5MemoryRetrievalBenchmark() async throws {
        try requireBenchmarkOptIn()
        try requirePhysicalDeviceForInference()
        let directory = try validatedLocalModelDirectory(environmentKey: "KNOCK_MLX_EMBEDDER_DIR")
        let modelSHA256 = try weightSHA256(in: directory)
        guard modelSHA256 == Self.expectedE5ModelSHA256 else {
            throw QualificationConfigurationError.unexpectedModelSHA256(
                expected: Self.expectedE5ModelSHA256,
                actual: modelSHA256
            )
        }

        Memory.clearCache()
        let loadStarted = CFAbsoluteTimeGetCurrent()
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
        )
        let loadSeconds = CFAbsoluteTimeGetCurrent() - loadStarted
        let shadow: any MemoryShadowQualificationReporting =
            MultilingualE5ReadOnlyShadow(container: container)
        let shadowReport = try await shadow.makeReport(
            fixture: MemoryShadowFixture(
                memories: documents.map {
                    MemoryShadowMemoryFixture(
                        memoryID: $0.id,
                        displayText: $0.text
                    )
                },
                queries: queries.map {
                    MemoryShadowQueryFixture(
                        queryID: $0.id,
                        locale: $0.locale,
                        expectedMemoryID: $0.expectedDocumentID,
                        displayText: $0.text
                    )
                }
            )
        )
        let report = RetrievalReport(
            model: "intfloat/multilingual-e5-small",
            modelSHA256: modelSHA256,
            queryCount: shadowReport.queryCount,
            correctCount: shadowReport.correctCount,
            recallAtOne: shadowReport.recallAtOne,
            p50Seconds: shadowReport.p50Seconds,
            p95Seconds: shadowReport.p95Seconds,
            loadSeconds: loadSeconds,
            minimumTopOneMargin: shadowReport.minimumTopOneMargin,
            localeResults: shadowReport.localeMetrics,
            predictions: shadowReport.predictions
        )
        try attach(report, name: "mlx-multilingual-e5-memory-retrieval.json")

        XCTAssertGreaterThanOrEqual(shadowReport.recallAtOne, 0.90)
        for locale in ["en-HK", "zh-Hans-HK", "yue-Hant-HK"] {
            XCTAssertGreaterThanOrEqual(
                try XCTUnwrap(shadowReport.localeMetrics[locale]).accuracy,
                0.90
            )
        }
        XCTAssertLessThanOrEqual(report.p95Seconds, 2.0)
    }

    func testLocalGemmaProducesStrictCommandEnvelope() async throws {
        try requireBenchmarkOptIn()
        try requirePhysicalDeviceForInference()
        let candidate = try selectedGemmaCandidate()
        let directory = try validatedGemmaDirectory(candidate: candidate)
        let transcript = "Remind me tomorrow at 9 AM to call John."
        let locale = "en-HK"
        let timezone = "Asia/Hong_Kong"
        let referenceMilliseconds: Int64 = 1_893_456_000_000
        let intentHint = try XCTUnwrap(
            try LocalVoiceUtterancePreflight.intentHint(for: transcript)
        )

        Memory.clearCache()
        let memoryBeforeLoad = Memory.snapshot()
        let loadStarted = CFAbsoluteTimeGetCurrent()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
        )
        let loadSeconds = CFAbsoluteTimeGetCurrent() - loadStarted
        let memoryAfterLoad = Memory.snapshot()

        let generationStarted = CFAbsoluteTimeGetCurrent()
        var extractedValues: [LocalCommandControlledField: String] = [:]
        var fieldOutputs: [String] = []
        for request in try LocalCommandControlledFieldPlan.requests(
            for: intentHint,
            transcript: transcript
        ) {
            let session = ChatSession(
                container,
                instructions: LocalCommandControlledFieldPrompt.system,
                generateParameters: .init(maxTokens: 32, temperature: 0)
            )
            let output = try await session.respond(
                to: LocalCommandControlledFieldPrompt.userText(
                    request: request,
                    transcript: transcript,
                    locale: locale
                )
            )
            fieldOutputs.append("\(request.field.rawValue)=\(output)")
            if let value = try LocalCommandControlledFieldOutputParser.value(
                from: output,
                request: request,
                transcript: transcript
            ) {
                extractedValues[request.field] = value
            }
        }
        let output = fieldOutputs.joined(separator: "\n")
        let generationSeconds = CFAbsoluteTimeGetCurrent() - generationStarted
        let memoryAfterGeneration = Memory.snapshot()
        try attach(GemmaSmokeReport(
            runtime: "MLX Swift",
            executionEnvironment: executionEnvironment,
            packageVersion: Self.qualificationPackageVersion,
            model: candidate.rawValue,
            loadSeconds: loadSeconds,
            generationSeconds: generationSeconds,
            rawOutput: output,
            extractedArgumentsJSON: nil,
            canonicalEnvelopeJSON: nil,
            memoryBeforeLoad: memoryBeforeLoad,
            memoryAfterLoad: memoryAfterLoad,
            memoryAfterGeneration: memoryAfterGeneration
        ), name: "\(candidate.attachmentStem)-command-envelope-raw.json")

        guard let trustedTimezone = TimeZone(identifier: timezone) else {
            throw LocalVoiceAdapterError.invalidModelOutput
        }
        XCTAssertEqual(
            extractedValues[.reminderTitle],
            "call John",
            "The model must extract the literal field correctly; deterministic grounding must not hide a bad model output."
        )
        let groundedArguments = try LocalCommandControlledFieldAssembler.arguments(
            for: intentHint,
            extractedValues: extractedValues,
            transcript: transcript,
            referenceMilliseconds: referenceMilliseconds,
            timezone: trustedTimezone
        )
        let argumentData = try JSONSerialization.data(
            withJSONObject: groundedArguments,
            options: [.sortedKeys]
        )
        let semanticDraft = try JSONSerialization.data(
            withJSONObject: [
                "intent": intentHint,
                "args": groundedArguments,
                "confidence": 0.99,
            ],
            options: [.sortedKeys]
        )
        let canonicalData = try LocalCommandEnvelopeCanonicalizer(
            makeIdentifier: { "mlx_qualification" }
        ).canonicalize(
            modelOutput: semanticDraft,
            context: .init(
                modelVersion: candidate.trustedModelVersion,
                localeIdentifier: locale,
                timezoneIdentifier: timezone
            ),
            validationMilliseconds: referenceMilliseconds
        )
        let envelope = try CommandEnvelope.decodeStrict(from: canonicalData)
        try attach(GemmaSmokeReport(
            runtime: "MLX Swift",
            executionEnvironment: executionEnvironment,
            packageVersion: Self.qualificationPackageVersion,
            model: candidate.rawValue,
            loadSeconds: loadSeconds,
            generationSeconds: generationSeconds,
            rawOutput: output,
            extractedArgumentsJSON: String(data: argumentData, encoding: .utf8),
            canonicalEnvelopeJSON: String(data: canonicalData, encoding: .utf8),
            memoryBeforeLoad: memoryBeforeLoad,
            memoryAfterLoad: memoryAfterLoad,
            memoryAfterGeneration: memoryAfterGeneration
        ), name: "\(candidate.attachmentStem)-command-envelope-validated.json")

        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.intent, "create_reminder")
        XCTAssertEqual(envelope.locale, locale)
        XCTAssertEqual(envelope.timezone, timezone)
        XCTAssertEqual(envelope.riskLevel, .low)
        XCTAssertFalse(envelope.needsConfirmation)
        XCTAssertEqual(envelope.args["title"], .string("call John"))
        XCTAssertNotNil(envelope.args["due_at"])
    }

    func testLocalGemmaMeetsGoldenCommandSafetyGates() async throws {
        try requireBenchmarkOptIn()
        try requirePhysicalDeviceForInference()
        let candidate = try selectedGemmaCandidate()
        let directory = try validatedGemmaDirectory(candidate: candidate)
        let dataset = try loadCommandGoldenDataset()
        let selectedLocales = Set(
            (ProcessInfo.processInfo.environment["KNOCK_MLX_GOLDEN_LOCALES"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let selectedExamples = selectedLocales.isEmpty
            ? dataset.examples
            : dataset.examples.filter { selectedLocales.contains($0.locale) }
        guard !selectedExamples.isEmpty else {
            XCTFail("KNOCK_MLX_GOLDEN_LOCALES did not match any golden examples")
            return
        }
        let referenceMilliseconds = try XCTUnwrap(
            LocalReminderDueAt.parseMilliseconds(dataset.referenceNow)
        )

        Memory.clearCache()
        let memoryBeforeLoad = Memory.snapshot()
        let loadStarted = CFAbsoluteTimeGetCurrent()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
        )
        let loadSeconds = CFAbsoluteTimeGetCurrent() - loadStarted
        let memoryAfterLoad = Memory.snapshot()

        var evaluatedCommands = 0
        var correctCommands = 0
        var expectedClarifications = 0
        var correctClarifications = 0
        var highRiskFalseExecutions = 0
        var evaluatedFields = 0
        var correctFields = 0
        var latencies: [Double] = []
        var commandLatencies: [Double] = []
        var fieldLatencies: [Double] = []
        var localeResults: [String: LocaleResult] = [:]
        var predictions: [CommandBenchmarkPrediction] = []

        for example in selectedExamples {
            let started = CFAbsoluteTimeGetCurrent()
            var rawOutput: String?
            var canonicalEnvelopeJSON: String?
            var actualIntent: String?
            var actualOutcome = "runtime_error"
            var errorDescription: String?
            var commandCorrect = false
            var fieldExtractionCorrect: Bool?

            do {
                guard let intentHint = try LocalVoiceUtterancePreflight.intentHint(
                    for: example.transcript
                ) else {
                    throw LocalCommandEnvelopeCanonicalizerError.clarificationRequired(
                        .unsupportedIntent
                    )
                }
                guard let timezone = TimeZone(identifier: example.timezone) else {
                    throw LocalVoiceAdapterError.invalidModelOutput
                }
                var extractedValues: [LocalCommandControlledField: String] = [:]
                var fieldOutputs: [String] = []
                var allFieldsCorrect = true
                for request in try LocalCommandControlledFieldPlan.requests(
                    for: intentHint,
                    transcript: example.transcript
                ) {
                    evaluatedFields += 1
                    let session = ChatSession(
                        container,
                        instructions: LocalCommandControlledFieldPrompt.system,
                        generateParameters: .init(maxTokens: 32, temperature: 0)
                    )
                    let fieldStarted = CFAbsoluteTimeGetCurrent()
                    let output = try await session.respond(
                        to: LocalCommandControlledFieldPrompt.userText(
                            request: request,
                            transcript: example.transcript,
                            locale: example.locale
                        )
                    )
                    fieldLatencies.append(CFAbsoluteTimeGetCurrent() - fieldStarted)
                    fieldOutputs.append("\(request.field.rawValue)=\(output)")
                    rawOutput = fieldOutputs.joined(separator: "\n")
                    if let value = try LocalCommandControlledFieldOutputParser.value(
                        from: output,
                        request: request,
                        transcript: example.transcript
                    ) {
                        extractedValues[request.field] = value
                        if value == expectedFieldValue(for: request.field, in: example) {
                            correctFields += 1
                        } else {
                            allFieldsCorrect = false
                        }
                    } else {
                        allFieldsCorrect = false
                    }
                }
                fieldExtractionCorrect = allFieldsCorrect
                let groundedArguments = try LocalCommandControlledFieldAssembler.arguments(
                    for: intentHint,
                    extractedValues: extractedValues,
                    transcript: example.transcript,
                    referenceMilliseconds: referenceMilliseconds,
                    timezone: timezone
                )
                let semanticDraft = try JSONSerialization.data(
                    withJSONObject: [
                        "intent": intentHint,
                        "args": groundedArguments,
                        "confidence": 0.9,
                    ],
                    options: [.sortedKeys]
                )
                let canonicalData = try LocalCommandEnvelopeCanonicalizer(
                    makeIdentifier: { "mlx_\(example.id)" }
                ).canonicalize(
                    modelOutput: semanticDraft,
                    context: .init(
                        modelVersion: candidate.trustedModelVersion,
                        localeIdentifier: example.locale,
                        timezoneIdentifier: example.timezone
                    ),
                    validationMilliseconds: referenceMilliseconds
                )
                let envelope = try CommandEnvelope.decodeStrict(from: canonicalData)
                canonicalEnvelopeJSON = String(data: canonicalData, encoding: .utf8)
                actualOutcome = "command"
                actualIntent = envelope.intent

                if example.expectedOutcome == "command" {
                    var expectedArguments: [String: VoiceAgentBridge.JSONValue] =
                        (example.expectedArguments ?? [:]).mapValues {
                            VoiceAgentBridge.JSONValue.string($0)
                        }
                    if let expectedDueAt = example.expectedDueAt {
                        expectedArguments["due_at"] = VoiceAgentBridge.JSONValue.string(
                            expectedDueAt
                        )
                    }
                    let expectedConfirmation = example.backendConfirmationRequired
                        ?? (example.expectedIntent == "send_message")
                    commandCorrect = allFieldsCorrect
                        && envelope.intent == example.expectedIntent
                        && envelope.args == expectedArguments
                        && envelope.needsConfirmation == expectedConfirmation
                        && envelope.riskLevel == (expectedConfirmation ? .high : .low)
                }
                if envelope.intent == "send_message",
                   example.expectedIntent != "send_message"
                {
                    highRiskFalseExecutions += 1
                }
            } catch {
                errorDescription = String(describing: error)
                if LocalVoiceCommandErrorPolicy.requiresClarification(error) {
                    actualOutcome = "clarification"
                }
            }

            let latency = CFAbsoluteTimeGetCurrent() - started
            latencies.append(latency)
            let isCorrect: Bool
            if example.expectedOutcome == "command" {
                evaluatedCommands += 1
                commandLatencies.append(latency)
                if commandCorrect { correctCommands += 1 }
                isCorrect = commandCorrect
                let previous = localeResults[example.locale] ?? .init(correct: 0, total: 0)
                localeResults[example.locale] = .init(
                    correct: previous.correct + (commandCorrect ? 1 : 0),
                    total: previous.total + 1
                )
            } else {
                expectedClarifications += 1
                let clarificationCorrect = actualOutcome == "clarification"
                if clarificationCorrect { correctClarifications += 1 }
                isCorrect = clarificationCorrect
            }
            predictions.append(.init(
                id: example.id,
                locale: example.locale,
                expectedOutcome: example.expectedOutcome,
                actualOutcome: actualOutcome,
                expectedIntent: example.expectedIntent,
                actualIntent: actualIntent,
                correct: isCorrect,
                fieldExtractionCorrect: fieldExtractionCorrect,
                latencySeconds: latency,
                rawOutput: rawOutput,
                canonicalEnvelopeJSON: canonicalEnvelopeJSON,
                error: errorDescription
            ))
            Memory.clearCache()
        }

        let accuracy = Double(correctCommands) / Double(max(1, evaluatedCommands))
        let fieldAccuracy = Double(correctFields) / Double(max(1, evaluatedFields))
        let report = CommandBenchmarkReport(
            runtime: "MLX Swift",
            executionEnvironment: executionEnvironment,
            packageVersion: Self.qualificationPackageVersion,
            model: candidate.rawValue,
            exampleCount: selectedExamples.count,
            evaluatedCommands: evaluatedCommands,
            correctCommands: correctCommands,
            pipelineCommandAccuracy: accuracy,
            evaluatedFields: evaluatedFields,
            correctFields: correctFields,
            fieldExtractionAccuracy: fieldAccuracy,
            expectedClarifications: expectedClarifications,
            correctClarifications: correctClarifications,
            highRiskFalseExecutions: highRiskFalseExecutions,
            loadSeconds: loadSeconds,
            overallP95Seconds: percentile(latencies, percentile: 0.95),
            commandP95Seconds: percentile(commandLatencies, percentile: 0.95),
            fieldP95Seconds: percentile(fieldLatencies, percentile: 0.95),
            localeResults: localeResults,
            predictions: predictions,
            memoryBeforeLoad: memoryBeforeLoad,
            memoryAfterLoad: memoryAfterLoad,
            memoryAfterBenchmark: Memory.snapshot()
        )
        try attach(
            report,
            name: "\(candidate.attachmentStem)-golden-command-benchmark.json"
        )

        XCTAssertGreaterThanOrEqual(accuracy, dataset.minimumPipelineCommandAccuracy)
        XCTAssertGreaterThanOrEqual(fieldAccuracy, dataset.minimumPipelineCommandAccuracy)
        XCTAssertEqual(correctClarifications, expectedClarifications)
        XCTAssertLessThanOrEqual(
            highRiskFalseExecutions,
            dataset.maximumHighRiskFalseExecutions
        )
        XCTAssertLessThanOrEqual(report.overallP95Seconds, 2.0)
        XCTAssertLessThanOrEqual(report.commandP95Seconds, 2.0)
        XCTAssertLessThanOrEqual(report.fieldP95Seconds, 2.0)
    }

    private func requireBenchmarkOptIn() throws {
        guard ProcessInfo.processInfo.environment["KNOCK_RUN_MLX_BENCHMARK"] == "1" else {
            throw XCTSkip("Set KNOCK_RUN_MLX_BENCHMARK=1 and local model directories to run MLX UAT.")
        }
    }

    private func requirePhysicalDeviceForInference() throws {
#if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment[
            "KNOCK_ALLOW_MLX_SIMULATOR_DIAGNOSTIC"
        ] == "1" else {
            throw XCTSkip(
                "MLX qualification requires a physical iPhone. Set KNOCK_ALLOW_MLX_SIMULATOR_DIAGNOSTIC=1 only for non-qualifying prompt diagnostics."
            )
        }
#endif
    }

    private var executionEnvironment: String {
#if targetEnvironment(simulator)
        return "iOS Simulator diagnostic (not device qualification)"
#else
        return "physical iPhone"
#endif
    }

    private func validatedLocalModelDirectory(environmentKey: String) throws -> URL {
        guard let rawPath = ProcessInfo.processInfo.environment[environmentKey], !rawPath.isEmpty else {
            throw XCTSkip("Missing \(environmentKey); network downloads are intentionally disabled in this target.")
        }
        let directory: URL
        if rawPath.hasPrefix("bundle:") {
            let relativePath = String(rawPath.dropFirst("bundle:".count))
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty,
                  !relativePath.hasPrefix("/"),
                  !components.contains("..") else {
                XCTFail("\(environmentKey) contains an unsafe test-bundle path")
                throw CocoaError(.fileReadInvalidFileName)
            }
            directory = components.reduce(Bundle(for: Self.self).bundleURL) { current, component in
                current.appendingPathComponent(String(component), isDirectory: true)
            }
        } else {
            directory = URL(fileURLWithPath: rawPath, isDirectory: true).resolvingSymlinksInPath()
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            XCTFail("\(environmentKey) must point to an existing local directory")
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("config.json").path
        ) else {
            XCTFail("Local model directory is missing config.json")
            throw CocoaError(.fileReadNoSuchFile)
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        guard files.contains(where: { $0.pathExtension == "safetensors" }) else {
            XCTFail("Local model directory is missing safetensors weights")
            throw CocoaError(.fileReadNoSuchFile)
        }
        return directory
    }

    private func weightSHA256(in directory: URL) throws -> String {
        let weightFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "safetensors" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard weightFiles.count == 1, let weightURL = weightFiles.first else {
            throw QualificationConfigurationError.unexpectedWeightFileCount(weightFiles.count)
        }
        let handle = try FileHandle(forReadingFrom: weightURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func selectedGemmaCandidate() throws -> GemmaCandidate {
        let configured = ProcessInfo.processInfo.environment["KNOCK_MLX_GEMMA_MODEL_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = configured.flatMap { $0.isEmpty ? nil : $0 }
            ?? GemmaCandidate.gemma3_1B.rawValue
        guard let candidate = GemmaCandidate(rawValue: modelID) else {
            throw QualificationConfigurationError.unsupportedModelID(modelID)
        }
        return candidate
    }

    private func validatedGemmaDirectory(candidate: GemmaCandidate) throws -> URL {
        let directory = try validatedLocalModelDirectory(
            environmentKey: "KNOCK_MLX_GEMMA_DIR"
        )
        let configurationURL = directory.appendingPathComponent("config.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: configurationURL))
        guard let configuration = object as? [String: Any],
              let modelType = configuration["model_type"] as? String,
              candidate.acceptedModelTypes.contains(modelType) else {
            let actual = ((object as? [String: Any])?["model_type"] as? String) ?? "missing"
            throw QualificationConfigurationError.unexpectedModelType(
                expected: candidate.acceptedModelTypes.sorted().joined(separator: " or "),
                actual: actual
            )
        }
        return directory
    }

    private func loadCommandGoldenDataset() throws -> CommandGoldenDataset {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(
            forResource: "VoiceCommandGoldenSet.v1",
            withExtension: "json"
        ) else {
            XCTFail("MLX qualification bundle is missing VoiceCommandGoldenSet.v1.json")
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(
            CommandGoldenDataset.self,
            from: Data(contentsOf: url)
        )
    }

    private func expectedFieldValue(
        for field: LocalCommandControlledField,
        in example: CommandGoldenExample
    ) -> String? {
        switch field {
        case .historyQuery:
            return example.expectedArguments?["q"]
        case .reminderTitle, .draftTitle:
            return example.expectedArguments?["title"]
        case .draftBody, .messageBody:
            return example.expectedArguments?["body"]
        case .messageRecipient:
            return example.expectedArguments?["recipient"]
        }
    }

    private func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int(ceil(Double(sorted.count) * percentile)) - 1
        return sorted[max(0, min(index, sorted.count - 1))]
    }

    private func attach<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let attachment = XCTAttachment(
            data: try encoder.encode(value),
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import Foundation
import MLX
import MLXEmbedders
import MLXLLM
import MLXLMCommon
import XCTest
@testable import VoiceAgentBridge

final class MLXLocalRuntimeQualificationTests: XCTestCase {
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

    private struct RetrievalPrediction: Codable {
        let queryID: String
        let locale: String
        let expectedDocumentID: String
        let predictedDocumentID: String
        let correct: Bool
        let topScore: Float
        let topOneMargin: Float
    }

    private struct RetrievalReport: Codable {
        let runtime: String
        let executionEnvironment: String
        let packageVersion: String
        let model: String
        let queryCount: Int
        let correctCount: Int
        let recallAtOne: Double
        let p50Seconds: Double
        let p95Seconds: Double
        let loadSeconds: Double
        let minimumTopOneMargin: Float
        let localeResults: [String: LocaleResult]
        let predictions: [RetrievalPrediction]
        let memoryBeforeLoad: GPU.Snapshot
        let memoryAfterLoad: GPU.Snapshot
        let memoryAfterBenchmark: GPU.Snapshot
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
        let expectedClarifications: Int
        let correctClarifications: Int
        let highRiskFalseExecutions: Int
        let loadSeconds: Double
        let overallP95Seconds: Double
        let commandP95Seconds: Double
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
            MLXEmbedders.ModelConfiguration.multilingual_e5_small.name,
            "intfloat/multilingual-e5-small"
        )
        XCTAssertEqual(
            LLMRegistry.gemma3_1B_qat_4bit.name,
            "mlx-community/gemma-3-1b-it-qat-4bit"
        )
    }

    func testMultilingualE5MemoryRetrievalBenchmark() async throws {
        try requireBenchmarkOptIn()
        try requirePhysicalDeviceForInference()
        let directory = try validatedLocalModelDirectory(environmentKey: "KNOCK_MLX_EMBEDDER_DIR")

        GPU.clearCache()
        let memoryBeforeLoad = GPU.snapshot()
        let loadStarted = CFAbsoluteTimeGetCurrent()
        let container = try await MLXEmbedders.loadModelContainer(
            configuration: .init(directory: directory)
        )
        let loadSeconds = CFAbsoluteTimeGetCurrent() - loadStarted
        let memoryAfterLoad = GPU.snapshot()

        let documentVectors = await embed(
            documents.map { "passage: \($0.text)" },
            using: container
        )
        XCTAssertEqual(documentVectors.count, documents.count)
        var correct = 0
        var localeResults: [String: LocaleResult] = [:]
        var margins: [Float] = []
        var perExampleSeconds: [Double] = []
        var predictions: [RetrievalPrediction] = []

        for query in queries {
            let inferenceStarted = CFAbsoluteTimeGetCurrent()
            let vectors = await embed(["query: \(query.text)"], using: container)
            perExampleSeconds.append(CFAbsoluteTimeGetCurrent() - inferenceStarted)
            guard let queryVector = vectors.first else {
                XCTFail("Embedding runtime returned no vector for \(query.id)")
                continue
            }
            let scored = zip(documents, documentVectors)
                .map { document, vector in (document.id, dot(queryVector, vector)) }
                .sorted { $0.1 > $1.1 }
            guard let predicted = scored.first else {
                XCTFail("No retrieval score was produced for \(query.id)")
                continue
            }
            let secondScore = scored.dropFirst().first?.1 ?? -.infinity
            let margin = predicted.1 - secondScore
            margins.append(margin)

            let isCorrect = predicted.0 == query.expectedDocumentID
            if isCorrect { correct += 1 }
            let previous = localeResults[query.locale] ?? .init(correct: 0, total: 0)
            localeResults[query.locale] = .init(
                correct: previous.correct + (isCorrect ? 1 : 0),
                total: previous.total + 1
            )
            predictions.append(
                .init(
                    queryID: query.id,
                    locale: query.locale,
                    expectedDocumentID: query.expectedDocumentID,
                    predictedDocumentID: predicted.0,
                    correct: isCorrect,
                    topScore: predicted.1,
                    topOneMargin: margin
                )
            )
        }

        let recallAtOne = Double(correct) / Double(queries.count)
        let report = RetrievalReport(
            runtime: "MLX Swift",
            executionEnvironment: executionEnvironment,
            packageVersion: "mlx-swift-lm 2.29.3 / mlx-swift 0.29.1",
            model: "intfloat/multilingual-e5-small",
            queryCount: queries.count,
            correctCount: correct,
            recallAtOne: recallAtOne,
            p50Seconds: percentile(perExampleSeconds, percentile: 0.50),
            p95Seconds: percentile(perExampleSeconds, percentile: 0.95),
            loadSeconds: loadSeconds,
            minimumTopOneMargin: margins.min() ?? 0,
            localeResults: localeResults,
            predictions: predictions,
            memoryBeforeLoad: memoryBeforeLoad,
            memoryAfterLoad: memoryAfterLoad,
            memoryAfterBenchmark: GPU.snapshot()
        )
        try attach(report, name: "mlx-multilingual-e5-memory-retrieval.json")

        XCTAssertGreaterThanOrEqual(recallAtOne, 0.90)
        for locale in ["en-HK", "zh-Hans-HK", "yue-Hant-HK"] {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(localeResults[locale]).accuracy, 0.90)
        }
        XCTAssertLessThanOrEqual(report.p95Seconds, 2.0)
    }

    func testLocalGemmaProducesStrictCommandEnvelope() async throws {
        try requireBenchmarkOptIn()
        try requirePhysicalDeviceForInference()
        let directory = try validatedLocalModelDirectory(environmentKey: "KNOCK_MLX_GEMMA_DIR")
        let transcript = "Remind me tomorrow at 9 AM to call John."
        let locale = "en-HK"
        let timezone = "Asia/Hong_Kong"
        let referenceMilliseconds: Int64 = 1_893_456_000_000
        let intentHint = try XCTUnwrap(
            try LocalVoiceUtterancePreflight.intentHint(for: transcript)
        )
        let trustedPrompt = try LocalCommandPrompt.userText(
            transcript: transcript,
            locale: locale,
            timezone: timezone,
            referenceMilliseconds: referenceMilliseconds,
            intentHint: intentHint
        )

        GPU.clearCache()
        let memoryBeforeLoad = GPU.snapshot()
        let loadStarted = CFAbsoluteTimeGetCurrent()
        let configuration = MLXLMCommon.ModelConfiguration(
            directory: directory,
            extraEOSTokens: ["<end_of_turn>"]
        )
        let container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
        let loadSeconds = CFAbsoluteTimeGetCurrent() - loadStarted
        let memoryAfterLoad = GPU.snapshot()
        let session = ChatSession(
            container,
            instructions: LocalCommandPrompt.system,
            generateParameters: .init(maxTokens: 128, temperature: 0)
        )

        let generationStarted = CFAbsoluteTimeGetCurrent()
        let output = try await session.respond(to: trustedPrompt)
        let generationSeconds = CFAbsoluteTimeGetCurrent() - generationStarted
        let memoryAfterGeneration = GPU.snapshot()
        try attach(GemmaSmokeReport(
            runtime: "MLX Swift",
            executionEnvironment: executionEnvironment,
            packageVersion: "mlx-swift-lm 2.29.3 / mlx-swift 0.29.1",
            model: "mlx-community/gemma-3-1b-it-qat-4bit",
            loadSeconds: loadSeconds,
            generationSeconds: generationSeconds,
            rawOutput: output,
            extractedArgumentsJSON: nil,
            canonicalEnvelopeJSON: nil,
            memoryBeforeLoad: memoryBeforeLoad,
            memoryAfterLoad: memoryAfterLoad,
            memoryAfterGeneration: memoryAfterGeneration
        ), name: "mlx-gemma3-1b-command-envelope-raw.json")

        let argumentData = try LiteRTModelOutputParser.extractJSONObject(
            from: LiteRTModelResponseTransport.jsonCandidate(from: output)
        )
        guard let modelArguments = try JSONSerialization.jsonObject(with: argumentData)
            as? [String: Any],
              let trustedTimezone = TimeZone(identifier: timezone)
        else {
            throw LocalVoiceAdapterError.invalidModelOutput
        }
        let groundedArguments = try LocalVoiceArgumentGrounder.arguments(
            for: intentHint,
            modelArguments: modelArguments,
            transcript: transcript,
            referenceMilliseconds: referenceMilliseconds,
            timezone: trustedTimezone
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
                modelVersion: "mlx-gemma-3-1b-it-qat-4bit",
                localeIdentifier: locale,
                timezoneIdentifier: timezone
            ),
            validationMilliseconds: referenceMilliseconds
        )
        let envelope = try CommandEnvelope.decodeStrict(from: canonicalData)
        try attach(GemmaSmokeReport(
            runtime: "MLX Swift",
            executionEnvironment: executionEnvironment,
            packageVersion: "mlx-swift-lm 2.29.3 / mlx-swift 0.29.1",
            model: "mlx-community/gemma-3-1b-it-qat-4bit",
            loadSeconds: loadSeconds,
            generationSeconds: generationSeconds,
            rawOutput: output,
            extractedArgumentsJSON: String(data: argumentData, encoding: .utf8),
            canonicalEnvelopeJSON: String(data: canonicalData, encoding: .utf8),
            memoryBeforeLoad: memoryBeforeLoad,
            memoryAfterLoad: memoryAfterLoad,
            memoryAfterGeneration: memoryAfterGeneration
        ), name: "mlx-gemma3-1b-command-envelope-validated.json")

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
        let directory = try validatedLocalModelDirectory(environmentKey: "KNOCK_MLX_GEMMA_DIR")
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

        GPU.clearCache()
        let memoryBeforeLoad = GPU.snapshot()
        let loadStarted = CFAbsoluteTimeGetCurrent()
        let configuration = MLXLMCommon.ModelConfiguration(
            directory: directory,
            extraEOSTokens: ["<end_of_turn>"]
        )
        let container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
        let loadSeconds = CFAbsoluteTimeGetCurrent() - loadStarted
        let memoryAfterLoad = GPU.snapshot()

        var evaluatedCommands = 0
        var correctCommands = 0
        var expectedClarifications = 0
        var correctClarifications = 0
        var highRiskFalseExecutions = 0
        var latencies: [Double] = []
        var commandLatencies: [Double] = []
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

            do {
                guard let intentHint = try LocalVoiceUtterancePreflight.intentHint(
                    for: example.transcript
                ) else {
                    throw LocalCommandEnvelopeCanonicalizerError.clarificationRequired(
                        .unsupportedIntent
                    )
                }
                let trustedPrompt = try LocalCommandPrompt.userText(
                    transcript: example.transcript,
                    locale: example.locale,
                    timezone: example.timezone,
                    referenceMilliseconds: referenceMilliseconds,
                    intentHint: intentHint
                )
                let session = ChatSession(
                    container,
                    instructions: LocalCommandPrompt.system,
                    generateParameters: .init(maxTokens: 128, temperature: 0)
                )
                let output = try await session.respond(to: trustedPrompt)
                rawOutput = output
                let argumentData = try LiteRTModelOutputParser.extractJSONObject(
                    from: LiteRTModelResponseTransport.jsonCandidate(from: output)
                )
                guard let modelArguments = try JSONSerialization.jsonObject(with: argumentData)
                    as? [String: Any],
                      let timezone = TimeZone(identifier: example.timezone)
                else {
                    throw LocalVoiceAdapterError.invalidModelOutput
                }
                let groundedArguments = try LocalVoiceArgumentGrounder.arguments(
                    for: intentHint,
                    modelArguments: modelArguments,
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
                        modelVersion: "mlx-gemma-3-1b-it-qat-4bit",
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
                    commandCorrect = envelope.intent == example.expectedIntent
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
                latencySeconds: latency,
                rawOutput: rawOutput,
                canonicalEnvelopeJSON: canonicalEnvelopeJSON,
                error: errorDescription
            ))
            GPU.clearCache()
        }

        let accuracy = Double(correctCommands) / Double(max(1, evaluatedCommands))
        let report = CommandBenchmarkReport(
            runtime: "MLX Swift",
            executionEnvironment: executionEnvironment,
            packageVersion: "mlx-swift-lm 2.29.3 / mlx-swift 0.29.1",
            model: "mlx-community/gemma-3-1b-it-qat-4bit",
            exampleCount: selectedExamples.count,
            evaluatedCommands: evaluatedCommands,
            correctCommands: correctCommands,
            pipelineCommandAccuracy: accuracy,
            expectedClarifications: expectedClarifications,
            correctClarifications: correctClarifications,
            highRiskFalseExecutions: highRiskFalseExecutions,
            loadSeconds: loadSeconds,
            overallP95Seconds: percentile(latencies, percentile: 0.95),
            commandP95Seconds: percentile(commandLatencies, percentile: 0.95),
            localeResults: localeResults,
            predictions: predictions,
            memoryBeforeLoad: memoryBeforeLoad,
            memoryAfterLoad: memoryAfterLoad,
            memoryAfterBenchmark: GPU.snapshot()
        )
        try attach(report, name: "mlx-gemma3-1b-golden-command-benchmark.json")

        XCTAssertGreaterThanOrEqual(accuracy, dataset.minimumPipelineCommandAccuracy)
        XCTAssertEqual(correctClarifications, expectedClarifications)
        XCTAssertLessThanOrEqual(
            highRiskFalseExecutions,
            dataset.maximumHighRiskFalseExecutions
        )
        XCTAssertLessThanOrEqual(report.overallP95Seconds, 2.0)
        XCTAssertLessThanOrEqual(report.commandP95Seconds, 2.0)
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

    private func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).reduce(0) { partial, values in
            partial + values.0 * values.1
        }
    }

    private func embed(
        _ texts: [String],
        using container: MLXEmbedders.ModelContainer
    ) async -> [[Float]] {
        await container.perform {
            (model: EmbeddingModel, tokenizer, pooling) -> [[Float]] in
            let encoded = texts.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
            let maximumLength = encoded.reduce(into: 16) { current, tokens in
                current = max(current, tokens.count)
            }
            let paddingToken = tokenizer.convertTokenToId("<pad>") ?? 0
            let padded = stacked(encoded.map { tokens in
                MLXArray(tokens + Array(repeating: paddingToken, count: maximumLength - tokens.count))
            })
            let attentionMask = padded .!= paddingToken
            let tokenTypes = MLXArray.zeros(like: padded)
            let output = pooling(
                model(
                    padded,
                    positionIds: nil,
                    tokenTypeIds: tokenTypes,
                    attentionMask: attentionMask
                ),
                normalize: true,
                applyLayerNorm: false
            )
            output.eval()
            return output.map { $0.asArray(Float.self) }
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

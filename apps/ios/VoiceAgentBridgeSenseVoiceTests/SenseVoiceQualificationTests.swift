import AVFoundation
import Darwin
import Foundation
import SherpaOnnx
import XCTest
@testable import VoiceAgentBridge

final class SenseVoiceQualificationTests: XCTestCase {
    private struct Dataset: Decodable {
        struct Example: Decodable {
            let id: String
            let locale: String
            let text: String
            let expectedOutcome: String?
            let expectedIntent: String?
            let expectedArguments: [String: String]?

            private enum CodingKeys: String, CodingKey {
                case id, locale, text
                case expectedOutcome = "expected_outcome"
                case expectedIntent = "expected_intent"
                case expectedArguments = "expected_args"
            }
        }

        let examples: [Example]
    }

    func testSherpaOnnxPackageLoads() {
        XCTAssertFalse(String(describing: SherpaOnnxOfflineRecognizer.self).isEmpty)
    }

    func testDeleteStagedSenseVoiceDataAfterUAT() throws {
        guard ProcessInfo.processInfo.environment["KNOCK_SENSEVOICE_DELETE_UAT_DATA"] == "1" else {
            throw XCTSkip("Set KNOCK_SENSEVOICE_DELETE_UAT_DATA=1 after physical UAT")
        }
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ).standardizedFileURL
        let target = documents.appendingPathComponent(
            "KnockKnockSenseVoiceUAT",
            isDirectory: true
        ).standardizedFileURL
        XCTAssertEqual(target.deletingLastPathComponent(), documents)
        XCTAssertEqual(target.lastPathComponent, "KnockKnockSenseVoiceUAT")
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        // The first qualification staging command copied this same, uniquely
        // identified UAT package into Documents itself. Remove only those
        // known artifacts, and only when the Dataset v2 marker proves their
        // provenance. Never enumerate or clear the full Documents directory.
        let legacyDataset = documents.appendingPathComponent(
            "KNOCK_KNOCK_VOICE_GOLDEN_V2.json"
        )
        if FileManager.default.fileExists(atPath: legacyDataset.path) {
            let legacy = try JSONDecoder().decode(
                DatasetMarker.self,
                from: Data(contentsOf: legacyDataset)
            )
            XCTAssertEqual(legacy.datasetID, "knock-knock-voice-golden-v2")
            for name in ["audio", "model", "KNOCK_KNOCK_VOICE_GOLDEN_V2.json"] {
                let legacyArtifact = documents.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: legacyArtifact.path) {
                    try FileManager.default.removeItem(at: legacyArtifact)
                }
            }
        }
    }

    private struct DatasetMarker: Decodable {
        let datasetID: String

        private enum CodingKeys: String, CodingKey {
            case datasetID = "dataset_id"
        }
    }

    func testConfiguredFilesTranscribeOnPhysicalDevice() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KNOCK_RUN_SENSEVOICE_UAT"] == "1" else {
            throw XCTSkip("Set KNOCK_RUN_SENSEVOICE_UAT=1 for the opt-in physical test")
        }

        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let root = documents.appendingPathComponent("KnockKnockSenseVoiceUAT", isDirectory: true)
        let datasetURL = root.appendingPathComponent("KNOCK_KNOCK_VOICE_GOLDEN_V2.json")
        let modelURL = try XCTUnwrap(findFile(named: "model.int8.onnx", below: root))
        let tokensURL = try XCTUnwrap(findFile(named: "tokens.txt", below: root))
        let dataset = try JSONDecoder().decode(Dataset.self, from: Data(contentsOf: datasetURL))
        let requestedFiles = environment["KNOCK_SENSEVOICE_AUDIO_FILES"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        XCTAssertFalse(requestedFiles.isEmpty, "Configure explicit consented UAT audio files")
        let requestedFilesByID = Dictionary(uniqueKeysWithValues: requestedFiles.map { fileName in
            (fileName.components(separatedBy: "__").first ?? fileName, fileName)
        })
        let selectedExamples = dataset.examples.filter { requestedFilesByID[$0.id] != nil }
        XCTAssertEqual(selectedExamples.count, requestedFiles.count)

        let threads = max(1, Int(environment["KNOCK_SENSEVOICE_NUM_THREADS"] ?? "2") ?? 2)
        let configuredLanguage = environment["KNOCK_SENSEVOICE_LANGUAGE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "auto"
        let modelLanguage = configuredLanguage == "auto" ? "" : configuredLanguage
        XCTAssertTrue(
            ["", "en", "zh", "yue"].contains(modelLanguage),
            "KNOCK_SENSEVOICE_LANGUAGE must be auto, en, zh, or yue"
        )
        let memoryBeforeLoad = residentMemoryBytes()
        let loadStarted = ProcessInfo.processInfo.systemUptime
        let senseVoice = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: modelURL.path,
            language: modelLanguage,
            useInverseTextNormalization: true
        )
        let model = sherpaOnnxOfflineModelConfig(
            tokens: tokensURL.path,
            numThreads: threads,
            provider: "cpu",
            debug: 0,
            modelType: "sense_voice",
            senseVoice: senseVoice
        )
        let features = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: features,
            modelConfig: model
        )
        let recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        let loadMilliseconds = milliseconds(since: loadStarted)
        let memoryAfterLoad = residentMemoryBytes()

        var localeEdits: [String: Int] = [:]
        var localeUnits: [String: Int] = [:]
        var localeTimes: [String: [Int]] = [:]
        var allTimes: [Int] = []
        var semanticCorrect = 0
        var semanticExamples = 0
        var highRiskFalseExecutions = 0
        for example in selectedExamples {
            let fileName = try XCTUnwrap(requestedFilesByID[example.id])
            let audioURL = try XCTUnwrap(findFile(named: fileName, below: root))
            let audio = try readAudio(at: audioURL)
            let started = ProcessInfo.processInfo.systemUptime
            let result = recognizer.decode(samples: audio.samples, sampleRate: audio.sampleRate)
            let inferenceMilliseconds = milliseconds(since: started)
            let transcript = cleanTranscript(result.text)
            let comparison = transcriptionDistance(
                expected: example.text,
                actual: transcript,
                locale: example.locale
            )
            localeEdits[example.locale, default: 0] += comparison.distance
            localeUnits[example.locale, default: 0] += comparison.referenceCount
            localeTimes[example.locale, default: []].append(inferenceMilliseconds)
            allTimes.append(inferenceMilliseconds)
            let semantic = example.expectedOutcome.map { _ in
                evaluateTranscript(transcript, for: example)
            }
            if semantic != nil { semanticExamples += 1 }
            if semantic?.correct == true { semanticCorrect += 1 }
            if semantic?.highRiskFalseExecution == true { highRiskFalseExecutions += 1 }
            print(
                "SENSEVOICE_SAMPLE language_mode=\(configuredLanguage) "
                    + "id=\(example.id) locale=\(example.locale) "
                    + "detected_language=\(result.lang) inference_ms=\(inferenceMilliseconds) "
                    + "edits=\(comparison.distance) reference_units=\(comparison.referenceCount) "
                    + "transcript=\(transcript)"
            )
            if let semantic {
                print(
                    "SENSEVOICE_SEMANTIC id=\(example.id) correct=\(semantic.correct) "
                        + "high_risk_false_execution=\(semantic.highRiskFalseExecution) "
                        + "outcome=\(semantic.outcome)"
                )
            }
        }

        for locale in localeUnits.keys.sorted() {
            let edits = localeEdits[locale, default: 0]
            let units = localeUnits[locale, default: 0]
            let accuracy = units == 0 ? 0 : max(0, 1 - Double(edits) / Double(units))
            print(
                "SENSEVOICE_LOCALE locale=\(locale) accuracy=\(accuracy) edits=\(edits) "
                    + "units=\(units) p95_inference_ms=\(percentile95(localeTimes[locale] ?? []))"
            )
        }
        let semanticAccuracy = semanticExamples == 0
            ? 0
            : Double(semanticCorrect) / Double(semanticExamples)
        print(
            "SENSEVOICE_SUMMARY language_mode=\(configuredLanguage) "
                + "samples=\(selectedExamples.count) threads=\(threads) "
                + "load_ms=\(loadMilliseconds) p95_inference_ms=\(percentile95(allTimes)) "
                + "resident_before_bytes=\(memoryBeforeLoad) "
                + "resident_after_load_bytes=\(memoryAfterLoad) "
                + "semantic_examples=\(semanticExamples) semantic_correct=\(semanticCorrect) "
                + "semantic_accuracy=\(semanticAccuracy) "
                + "high_risk_false_executions=\(highRiskFalseExecutions)"
        )
    }

    private func evaluateTranscript(
        _ transcript: String,
        for example: Dataset.Example
    ) -> (correct: Bool, highRiskFalseExecution: Bool, outcome: String) {
        let generator = DeterministicCommandGenerator(
            locale: Locale(identifier: example.locale),
            timezone: TimeZone(identifier: "Asia/Hong_Kong")!,
            deviceID: "sensevoice-qualification",
            identifierFactory: { example.id },
            nowMilliseconds: { 1_786_543_200_000 }
        )
        var generated: Result<Data, Error>?
        generator.generateCommand(for: transcript) { generated = $0 }
        do {
            let envelope = try CommandEnvelope.decodeStrict(from: try XCTUnwrap(generated).get())
            if example.expectedOutcome == "clarification" {
                return (
                    false,
                    envelope.riskLevel == .high || envelope.riskLevel == .destructive,
                    "unexpected_\(envelope.intent)"
                )
            }
            let expectedArguments = example.expectedArguments?.mapValues(JSONValue.string) ?? [:]
            let correct = envelope.intent == example.expectedIntent
                && envelope.args == expectedArguments
                && (envelope.intent != "send_message"
                    || (envelope.riskLevel == .high && envelope.needsConfirmation))
            return (correct, false, correct ? "command_match" : "command_mismatch")
        } catch {
            let clarified = LocalVoiceCommandErrorPolicy.requiresClarification(error)
            return (
                example.expectedOutcome == "clarification" && clarified,
                false,
                clarified ? "clarification" : "error"
            )
        }
    }

    private func readAudio(at url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        XCTAssertEqual(format.channelCount, 1, "SenseVoice UAT requires mono audio")
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw NSError(domain: "SenseVoiceQualification", code: 1)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?.pointee else {
            throw NSError(domain: "SenseVoiceQualification", code: 2)
        }
        return (
            Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
            Int(format.sampleRate.rounded())
        )
    }

    private func findFile(named name: String, below root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    private func cleanTranscript(_ value: String) -> String {
        value.replacingOccurrences(
            of: "<\\|[^>]+\\|>",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcriptionDistance(
        expected: String,
        actual: String,
        locale: String
    ) -> (distance: Int, referenceCount: Int) {
        if locale == "en-HK" {
            let expectedWords = normalizedEnglish(expected)
            let actualWords = normalizedEnglish(actual)
            return (levenshtein(expectedWords, actualWords), expectedWords.count)
        }
        let expectedCharacters = normalizedCJK(expected)
        let actualCharacters = normalizedCJK(actual)
        return (levenshtein(expectedCharacters, actualCharacters), expectedCharacters.count)
    }

    private func normalizedEnglish(_ value: String) -> [String] {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func normalizedCJK(_ value: String) -> [Character] {
        Array(value.lowercased().filter { character in
            character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        })
    }

    private func levenshtein<Element: Equatable>(_ lhs: [Element], _ rhs: [Element]) -> Int {
        var previous = Array(0 ... rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(rhs.count + 1)
            for (rightIndex, right) in rhs.enumerated() {
                current.append(
                    min(
                        current[rightIndex] + 1,
                        previous[rightIndex + 1] + 1,
                        previous[rightIndex] + (left == right ? 0 : 1)
                    )
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private func percentile95(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[index]
    }

    private func milliseconds(since started: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - started) * 1_000).rounded())
    }

    private func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}

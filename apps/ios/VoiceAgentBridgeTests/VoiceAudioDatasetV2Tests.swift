import AVFoundation
import CryptoKit
import Foundation
import Speech
import XCTest
@testable import VoiceAgentBridge

private struct VoiceAudioDatasetV2: Decodable {
    struct ReleaseGates: Decodable {
        let minimumEndToEndCommandSemanticAccuracy: Double
        let minimumAccuracyPerLocale: Double
        let minimumClarificationRecall: Double
        let maximumHighRiskFalseExecutions: Int
        let sendMessageConfirmationRequired: Bool

        enum CodingKeys: String, CodingKey {
            case minimumEndToEndCommandSemanticAccuracy = "minimum_end_to_end_command_semantic_accuracy"
            case minimumAccuracyPerLocale = "minimum_accuracy_per_locale"
            case minimumClarificationRecall = "minimum_clarification_recall"
            case maximumHighRiskFalseExecutions = "maximum_high_risk_false_executions"
            case sendMessageConfirmationRequired = "send_message_confirmation_required"
        }
    }

    struct Example: Decodable {
        let id: String
        let locale: String
        let text: String
        let expectedOutcome: String
        let expectedIntent: String?
        let expectedArguments: [String: String]?
        let riskLevel: String?
        let needsConfirmation: Bool?

        enum CodingKeys: String, CodingKey {
            case id, locale, text
            case expectedOutcome = "expected_outcome"
            case expectedIntent = "expected_intent"
            case expectedArguments = "expected_args"
            case riskLevel = "risk_level"
            case needsConfirmation = "needs_confirmation"
        }
    }

    let schemaVersion: Int
    let referenceNow: String
    let timezone: String
    let releaseGates: ReleaseGates
    let humanRecordingSubset: [String]
    let examples: [Example]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case referenceNow = "reference_now"
        case timezone
        case releaseGates = "release_gates"
        case humanRecordingSubset = "human_recording_subset"
        case examples
    }
}

private struct VoiceAudioSTTResult: Codable {
    let exampleID: String
    let locale: String
    let profile: String
    let relativePath: String
    let expectedText: String
    let transcript: String?
    let errorCategory: String?
    let sttMilliseconds: Int
    let editDistance: Int?
    let referenceUnitCount: Int?

    enum CodingKeys: String, CodingKey {
        case exampleID = "example_id"
        case locale, profile
        case relativePath = "relative_path"
        case expectedText = "expected_text"
        case transcript
        case errorCategory = "error_category"
        case sttMilliseconds = "stt_ms"
        case editDistance = "edit_distance"
        case referenceUnitCount = "reference_unit_count"
    }
}

private struct VoiceAudioSTTReport: Codable {
    let schemaVersion: Int
    let device: String
    let generatedAt: String
    let sampleCount: Int
    let successfulTranscriptions: Int
    let results: [VoiceAudioSTTResult]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case device
        case generatedAt = "generated_at"
        case sampleCount = "sample_count"
        case successfulTranscriptions = "successful_transcriptions"
        case results
    }
}

private struct VoiceAudioManifestRow: Decodable {
    let exampleID: String
    let profile: String
    let relativePath: String
    let sha256: String
    let durationMilliseconds: Int
    let sampleRate: Int
    let channels: Int
    let sourceType: String
    let ttsEngine: String
    let voiceID: String

    enum CodingKeys: String, CodingKey {
        case exampleID = "example_id"
        case profile
        case relativePath = "relative_path"
        case sha256
        case durationMilliseconds = "duration_ms"
        case sampleRate = "sample_rate_hz"
        case channels
        case sourceType = "source_type"
        case ttsEngine = "tts_engine"
        case voiceID = "voice_id"
    }
}

private struct VoiceWAVInspection {
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    let audioFormat: Int
    let sampleCount: Int
    let containsHardClipping: Bool
}

private enum VoiceAudioDatasetV2Error: LocalizedError {
    case invalidRoot
    case invalidManifestLine(Int)
    case invalidWAV(String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            return "Voice Dataset v2 root does not contain the required dataset and manifest files."
        case let .invalidManifestLine(line):
            return "Voice Dataset v2 manifest contains invalid JSON on line \(line)."
        case let .invalidWAV(reason):
            return "Voice Dataset v2 WAV is invalid: \(reason)"
        }
    }
}

private struct VoiceAudioDatasetV2Package {
    static let environmentKey = "KNOCK_VOICE_AUDIO_DATASET_ROOT"
    static let stagedDirectoryName = "KnockKnockVoiceAudioUAT"

    let rootURL: URL
    let dataset: VoiceAudioDatasetV2
    let manifest: [VoiceAudioManifestRow]

    static func resolve() throws -> VoiceAudioDatasetV2Package? {
        let environment = ProcessInfo.processInfo.environment
        let rootURL: URL
        if let configured = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty
        {
            rootURL = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            let documents = try XCTUnwrap(
                FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            )
            rootURL = documents.appendingPathComponent(stagedDirectoryName, isDirectory: true)
            guard FileManager.default.fileExists(atPath: rootURL.path) else { return nil }
        }

        let datasetURL = rootURL.appendingPathComponent(
            "KNOCK_KNOCK_VOICE_GOLDEN_V2.json",
            isDirectory: false
        )
        let generatedRoot = rootURL.appendingPathComponent(
            "voice-golden-v2-generated",
            isDirectory: true
        )
        let manifestURL = generatedRoot.appendingPathComponent(
            "audio-manifest.jsonl",
            isDirectory: false
        )
        guard FileManager.default.fileExists(atPath: datasetURL.path),
              FileManager.default.fileExists(atPath: manifestURL.path)
        else { throw VoiceAudioDatasetV2Error.invalidRoot }

        let dataset = try JSONDecoder().decode(
            VoiceAudioDatasetV2.self,
            from: Data(contentsOf: datasetURL)
        )
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
        let decoder = JSONDecoder()
        let manifest = try manifestText.split(whereSeparator: \.isNewline)
            .enumerated()
            .map { index, line -> VoiceAudioManifestRow in
                guard let data = String(line).data(using: .utf8),
                      let row = try? decoder.decode(VoiceAudioManifestRow.self, from: data)
                else { throw VoiceAudioDatasetV2Error.invalidManifestLine(index + 1) }
                return row
            }
        return VoiceAudioDatasetV2Package(rootURL: rootURL, dataset: dataset, manifest: manifest)
    }

    func audioURL(for row: VoiceAudioManifestRow) -> URL {
        rootURL
            .appendingPathComponent("voice-golden-v2-generated", isDirectory: true)
            .appendingPathComponent(row.relativePath, isDirectory: false)
    }
}

final class VoiceAudioDatasetV2Tests: XCTestCase {
    func testConfiguredDatasetHasUniqueValidAudioAndSafeReleaseGates() throws {
        guard let package = try VoiceAudioDatasetV2Package.resolve() else {
            throw XCTSkip("Voice Dataset v2 is not configured for this test run")
        }

        let dataset = package.dataset
        let manifest = package.manifest
        var failures: [String] = []

        expect(dataset.schemaVersion == 2, "schema_version must be 2", failures: &failures)
        expect(dataset.examples.count == 48, "dataset must contain 48 examples", failures: &failures)
        expect(dataset.humanRecordingSubset.count == 12, "human subset must contain 12 IDs", failures: &failures)
        expect(manifest.count == 144, "manifest must contain 144 rows", failures: &failures)
        expect(Set(dataset.examples.map(\.id)).count == 48, "example IDs must be unique", failures: &failures)
        expect(Set(manifest.map(\.relativePath)).count == 144, "audio paths must be unique", failures: &failures)
        expect(Set(manifest.map(\.sha256)).count == 144, "audio content hashes must be unique", failures: &failures)
        expect(Set(dataset.examples.map(\.locale)) == ["en-HK", "zh-Hans-HK", "yue-Hant-HK"], "required locales are missing", failures: &failures)
        expect(dataset.releaseGates.minimumEndToEndCommandSemanticAccuracy == 0.95, "command accuracy gate must be 0.95", failures: &failures)
        expect(dataset.releaseGates.minimumAccuracyPerLocale == 0.90, "per-locale gate must be 0.90", failures: &failures)
        expect(dataset.releaseGates.minimumClarificationRecall == 0.95, "clarification gate must be 0.95", failures: &failures)
        expect(dataset.releaseGates.maximumHighRiskFalseExecutions == 0, "high-risk false execution gate must be zero", failures: &failures)
        expect(dataset.releaseGates.sendMessageConfirmationRequired, "send_message confirmation must remain required", failures: &failures)

        let examplesByID = Dictionary(uniqueKeysWithValues: dataset.examples.map { ($0.id, $0) })
        let profiles = Set(["clean_normal", "fast_phone", "noise_snr15"])
        for example in dataset.examples {
            let rows = manifest.filter { $0.exampleID == example.id }
            expect(Set(rows.map(\.profile)) == profiles, "\(example.id) must have all three profiles", failures: &failures)
            if example.expectedIntent == "send_message" {
                expect(example.riskLevel == "high", "\(example.id) must be high risk", failures: &failures)
                expect(example.needsConfirmation == true, "\(example.id) must require confirmation", failures: &failures)
            }
        }

        for row in manifest {
            expect(examplesByID[row.exampleID] != nil, "manifest references unknown example \(row.exampleID)", failures: &failures)
            expect(profiles.contains(row.profile), "\(row.exampleID) has unknown profile \(row.profile)", failures: &failures)
            expect(row.sourceType == "synthetic", "\(row.exampleID) must be synthetic", failures: &failures)
            expect(!row.ttsEngine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(row.exampleID) is missing tts_engine", failures: &failures)
            expect(!row.voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(row.exampleID) is missing voice_id", failures: &failures)

            let audioURL = package.audioURL(for: row)
            guard let data = try? Data(contentsOf: audioURL) else {
                failures.append("missing audio: \(row.relativePath)")
                continue
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            expect(digest == row.sha256, "hash mismatch: \(row.relativePath)", failures: &failures)
            do {
                let inspection = try inspectWAV(data, path: row.relativePath)
                expect(inspection.audioFormat == 1, "\(row.relativePath) must use integer PCM", failures: &failures)
                expect(inspection.sampleRate == 16_000 && row.sampleRate == 16_000, "\(row.relativePath) must be 16 kHz", failures: &failures)
                expect(inspection.channels == 1 && row.channels == 1, "\(row.relativePath) must be mono", failures: &failures)
                expect(inspection.bitsPerSample == 16, "\(row.relativePath) must be signed 16-bit PCM", failures: &failures)
                expect(!inspection.containsHardClipping, "\(row.relativePath) contains hard clipping", failures: &failures)
                let duration = Int((Double(inspection.sampleCount) / Double(inspection.sampleRate) * 1_000).rounded())
                expect(abs(duration - row.durationMilliseconds) <= 2, "duration mismatch: \(row.relativePath)", failures: &failures)
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func expect(_ condition: @autoclosure () -> Bool, _ message: String, failures: inout [String]) {
        if !condition() { failures.append(message) }
    }

    private func inspectWAV(_ data: Data, path: String) throws -> VoiceWAVInspection {
        guard data.count >= 12,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE"
        else { throw VoiceAudioDatasetV2Error.invalidWAV("\(path) is not RIFF/WAVE") }

        var offset = 12
        var format: (audioFormat: Int, channels: Int, sampleRate: Int, bitsPerSample: Int)?
        var samples: Data?
        while offset + 8 <= data.count {
            let identifier = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let size = Int(readUInt32(data, at: offset + 4))
            let bodyStart = offset + 8
            let bodyEnd = bodyStart + size
            guard bodyEnd <= data.count else {
                throw VoiceAudioDatasetV2Error.invalidWAV("\(path) contains a truncated chunk")
            }
            if identifier == "fmt ", size >= 16 {
                format = (
                    Int(readUInt16(data, at: bodyStart)),
                    Int(readUInt16(data, at: bodyStart + 2)),
                    Int(readUInt32(data, at: bodyStart + 4)),
                    Int(readUInt16(data, at: bodyStart + 14))
                )
            } else if identifier == "data" {
                samples = data.subdata(in: bodyStart..<bodyEnd)
            }
            offset = bodyEnd + (size % 2)
        }
        guard let format, let samples, !samples.isEmpty, samples.count.isMultiple(of: 2) else {
            throw VoiceAudioDatasetV2Error.invalidWAV("\(path) is missing fmt or sample data")
        }
        var clipped = false
        samples.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: Int16.self)
            clipped = values.contains { $0 == Int16.min || $0 == Int16.max }
        }
        return VoiceWAVInspection(
            sampleRate: format.sampleRate,
            channels: format.channels,
            bitsPerSample: format.bitsPerSample,
            audioFormat: format.audioFormat,
            sampleCount: samples.count / max(1, format.channels * (format.bitsPerSample / 8)),
            containsHardClipping: clipped
        )
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

/// Opt-in Layer A entry point. The WAV bytes are decoded with AVAudioFile and
/// fed into the same SystemOnDeviceSpeechTranscriber used by push-to-talk.
/// It deliberately refuses to run if package integrity fails first.
final class VoiceAudioSTTEvaluationTests: XCTestCase {
    func testConfiguredAudioRunsThroughProductionOnDeviceSTT() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KNOCK_RUN_VOICE_AUDIO_STT_UAT"] == "1" else {
            throw XCTSkip("Set KNOCK_RUN_VOICE_AUDIO_STT_UAT=1 for the opt-in STT evaluation")
        }
        guard let package = try VoiceAudioDatasetV2Package.resolve() else {
            XCTFail("Voice Dataset v2 is required for the STT evaluation")
            return
        }
        guard package.manifest.count == 144,
              Set(package.manifest.map(\.relativePath)).count == 144,
              Set(package.manifest.map(\.sha256)).count == 144
        else {
            XCTFail("Dataset integrity gate failed; refusing to report STT accuracy for duplicated audio")
            return
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            XCTFail("Speech recognition permission must be authorized before physical STT UAT")
            return
        }

        let selectedProfiles = Set(
            environment["KNOCK_VOICE_AUDIO_PROFILES"]?
                .split(separator: ",")
                .map(String.init) ?? ["clean_normal"]
        )
        let explicitIDs = Set(
            environment["KNOCK_VOICE_AUDIO_IDS"]?
                .split(separator: ",")
                .map(String.init) ?? []
        )
        let selectedIDs = explicitIDs.isEmpty
            ? (environment["KNOCK_VOICE_AUDIO_HUMAN_SUBSET_ONLY"] == "1"
                ? Set(package.dataset.humanRecordingSubset)
                : Set(package.dataset.examples.map(\.id)))
            : explicitIDs
        let limit = Int(environment["KNOCK_VOICE_AUDIO_LIMIT"] ?? "")
        let examplesByID = Dictionary(
            uniqueKeysWithValues: package.dataset.examples.map { ($0.id, $0) }
        )
        var selectedRows = package.manifest.filter {
            selectedIDs.contains($0.exampleID) && selectedProfiles.contains($0.profile)
        }.sorted {
            ($0.exampleID, $0.profile) < ($1.exampleID, $1.profile)
        }
        if let limit, limit > 0 {
            selectedRows = Array(selectedRows.prefix(limit))
        }
        XCTAssertFalse(selectedRows.isEmpty, "No audio rows matched the configured filters")

        var results: [VoiceAudioSTTResult] = []
        for row in selectedRows {
            let example = try XCTUnwrap(examplesByID[row.exampleID])
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let transcript = try await transcribe(
                    package.audioURL(for: row),
                    locale: Locale(identifier: example.locale)
                )
                let elapsed = Int(((ProcessInfo.processInfo.systemUptime - started) * 1_000).rounded())
                let comparison = transcriptionDistance(
                    expected: example.text,
                    actual: transcript,
                    locale: example.locale
                )
                results.append(
                    VoiceAudioSTTResult(
                        exampleID: example.id,
                        locale: example.locale,
                        profile: row.profile,
                        relativePath: row.relativePath,
                        expectedText: example.text,
                        transcript: transcript,
                        errorCategory: nil,
                        sttMilliseconds: elapsed,
                        editDistance: comparison.distance,
                        referenceUnitCount: comparison.referenceCount
                    )
                )
            } catch {
                let elapsed = Int(((ProcessInfo.processInfo.systemUptime - started) * 1_000).rounded())
                results.append(
                    VoiceAudioSTTResult(
                        exampleID: example.id,
                        locale: example.locale,
                        profile: row.profile,
                        relativePath: row.relativePath,
                        expectedText: example.text,
                        transcript: nil,
                        errorCategory: "stt_failure",
                        sttMilliseconds: elapsed,
                        editDistance: nil,
                        referenceUnitCount: nil
                    )
                )
            }
        }

        try writeReport(results, package: package, environment: environment)
        XCTAssertEqual(
            results.filter { $0.errorCategory == nil }.count,
            selectedRows.count,
            "Every selected WAV must produce a final on-device transcript"
        )
    }

    private func transcribe(_ url: URL, locale: Locale) async throws -> String {
        let transcriber = SystemOnDeviceSpeechTranscriber(locale: locale)
        try transcriber.reset()
        let file = try AVAudioFile(forReading: url)
        while file.framePosition < file.length {
            let remaining = min(4_096, file.length - file.framePosition)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(remaining)
            ) else { throw VoiceAudioDatasetV2Error.invalidWAV(url.lastPathComponent) }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try transcriber.append(buffer)
        }

        let completed = expectation(description: "final transcript for \(url.lastPathComponent)")
        var recognitionResult: Result<String, Error>?
        transcriber.finish { result in
            recognitionResult = result
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 20)
        let transcript = try XCTUnwrap(recognitionResult).get()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw LocalVoiceAdapterError.invalidModelOutput }
        return transcript
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
        var previous = Array(0...rhs.count)
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

    private func writeReport(
        _ results: [VoiceAudioSTTResult],
        package: VoiceAudioDatasetV2Package,
        environment: [String: String]
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let device = environment["KNOCK_VOICE_RESULT_DEVICE"] ?? "unspecified-ios-device"
        let report = VoiceAudioSTTReport(
            schemaVersion: 1,
            device: device,
            generatedAt: formatter.string(from: Date()),
            sampleCount: results.count,
            successfulTranscriptions: results.filter { $0.errorCategory == nil }.count,
            results: results
        )
        let resultsDirectory = package.rootURL
            .appendingPathComponent("voice-golden-v2-generated", isDirectory: true)
            .appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resultsDirectory,
            withIntermediateDirectories: true
        )
        let safeDevice = device.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "-",
            options: .regularExpression
        )
        let destination = resultsDirectory.appendingPathComponent(
            "\(safeDevice)-stt-results.json",
            isDirectory: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: destination, options: .atomic)
    }
}

#if canImport(CLiteRTLM)

private struct VoiceAudioPipelineResult: Codable {
    let exampleID: String
    let locale: String
    let profile: String
    let expectedOutcome: String
    let transcript: String?
    let intent: String?
    let args: [String: JSONValue]?
    let correct: Bool
    let failureCategory: String?
    let sttMilliseconds: Int
    let intentMilliseconds: Int
    let totalMilliseconds: Int

    enum CodingKeys: String, CodingKey {
        case exampleID = "example_id"
        case locale, profile
        case expectedOutcome = "expected_outcome"
        case transcript, intent, args, correct
        case failureCategory = "failure_category"
        case sttMilliseconds = "stt_ms"
        case intentMilliseconds = "intent_ms"
        case totalMilliseconds = "total_ms"
    }
}

private struct VoiceAudioPipelineSummary: Codable {
    let schemaVersion: Int
    let device: String
    let sampleCount: Int
    let commandCorrect: Int
    let commandCount: Int
    let clarificationCorrect: Int
    let clarificationCount: Int
    let highRiskFalseExecutions: Int
    let commandAccuracyByLocale: [String: Double]
    let sttP50Milliseconds: Int
    let sttP95Milliseconds: Int
    let intentP50Milliseconds: Int
    let intentP95Milliseconds: Int
    let totalP50Milliseconds: Int
    let totalP95Milliseconds: Int
    let results: [VoiceAudioPipelineResult]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case device
        case sampleCount = "sample_count"
        case commandCorrect = "command_correct"
        case commandCount = "command_count"
        case clarificationCorrect = "clarification_correct"
        case clarificationCount = "clarification_count"
        case highRiskFalseExecutions = "high_risk_false_executions"
        case commandAccuracyByLocale = "command_accuracy_by_locale"
        case sttP50Milliseconds = "stt_p50_ms"
        case sttP95Milliseconds = "stt_p95_ms"
        case intentP50Milliseconds = "intent_p50_ms"
        case intentP95Milliseconds = "intent_p95_ms"
        case totalP50Milliseconds = "total_p50_ms"
        case totalP95Milliseconds = "total_p95_ms"
        case results
    }
}

/// Opt-in complete deterministic Layer A gate:
/// WAV -> production on-device STT -> signed Gemma -> strict envelope policy.
/// It never creates an API client, so clarification samples cannot submit.
final class VoiceAudioPipelineEvaluationTests: XCTestCase {
    func testConfiguredAudioMeetsSemanticAndSafetyGates() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KNOCK_RUN_VOICE_AUDIO_PIPELINE_UAT"] == "1" else {
            throw XCTSkip("Set KNOCK_RUN_VOICE_AUDIO_PIPELINE_UAT=1 for full Layer A UAT")
        }
        guard let package = try VoiceAudioDatasetV2Package.resolve() else {
            XCTFail("Voice Dataset v2 is required for Layer A UAT")
            return
        }
        guard package.manifest.count == 144,
              Set(package.manifest.map(\.relativePath)).count == 144,
              Set(package.manifest.map(\.sha256)).count == 144
        else {
            XCTFail("Dataset integrity gate failed; refusing to run semantic evaluation")
            return
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            XCTFail("Speech recognition permission must be authorized before Layer A UAT")
            return
        }
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        guard let modelInputs = try VoiceModelUATInputResolver().resolve(
            environment: environment,
            documentsDirectory: documents
        ) else {
            XCTFail("A signed staged model is required for Layer A UAT")
            return
        }
        let modelManifest = try ModelManifest.decodeStrict(
            from: Data(contentsOf: modelInputs.manifestURL)
        )
        try Ed25519ModelArtifactVerifier(publicKeyRawRepresentation: modelInputs.publicKey)
            .verifyArtifact(at: modelInputs.artifactURL, against: modelManifest)

        let profiles = Set(
            environment["KNOCK_VOICE_AUDIO_PROFILES"]?
                .split(separator: ",").map(String.init) ?? ["clean_normal"]
        )
        let explicitIDs = Set(
            environment["KNOCK_VOICE_AUDIO_IDS"]?
                .split(separator: ",").map(String.init) ?? []
        )
        let ids = explicitIDs.isEmpty
            ? Set(package.dataset.examples.map(\.id))
            : explicitIDs
        let limit = Int(environment["KNOCK_VOICE_AUDIO_LIMIT"] ?? "")
        var rows = package.manifest.filter {
            ids.contains($0.exampleID) && profiles.contains($0.profile)
        }.sorted { ($0.exampleID, $0.profile) < ($1.exampleID, $1.profile) }
        if let limit, limit > 0 { rows = Array(rows.prefix(limit)) }
        XCTAssertFalse(rows.isEmpty, "No audio rows matched the Layer A filters")

        let examples = Dictionary(
            uniqueKeysWithValues: package.dataset.examples.map { ($0.id, $0) }
        )
        let referenceMilliseconds = try XCTUnwrap(
            LocalReminderDueAt.parseMilliseconds(package.dataset.referenceNow)
        )
        let timezone = try XCTUnwrap(TimeZone(identifier: package.dataset.timezone))
        var results: [VoiceAudioPipelineResult] = []

        for locale in Set(rows.compactMap { examples[$0.exampleID]?.locale }).sorted() {
            let generator = try GemmaCommandGenerator(
                modelURL: modelInputs.artifactURL,
                modelVersion: modelManifest.modelVersion,
                useGPU: environment["KNOCK_VOICE_USE_GPU"] == "1",
                locale: Locale(identifier: locale),
                timezone: timezone,
                nowMilliseconds: { referenceMilliseconds }
            )
            for row in rows where examples[row.exampleID]?.locale == locale {
                let example = try XCTUnwrap(examples[row.exampleID])
                let totalStart = ProcessInfo.processInfo.systemUptime
                let sttStart = ProcessInfo.processInfo.systemUptime
                let transcript: String
                do {
                    transcript = try await transcribe(
                        package.audioURL(for: row),
                        locale: Locale(identifier: locale)
                    )
                } catch {
                    let total = milliseconds(since: totalStart)
                    results.append(
                        VoiceAudioPipelineResult(
                            exampleID: example.id,
                            locale: locale,
                            profile: row.profile,
                            expectedOutcome: example.expectedOutcome,
                            transcript: nil,
                            intent: nil,
                            args: nil,
                            correct: false,
                            failureCategory: "stt_failure",
                            sttMilliseconds: total,
                            intentMilliseconds: 0,
                            totalMilliseconds: total
                        )
                    )
                    continue
                }
                let sttMilliseconds = milliseconds(since: sttStart)
                let intentStart = ProcessInfo.processInfo.systemUptime
                let generation = await generate(transcript, with: generator)
                let intentMilliseconds = milliseconds(since: intentStart)
                let totalMilliseconds = milliseconds(since: totalStart)
                results.append(
                    evaluate(
                        example: example,
                        row: row,
                        transcript: transcript,
                        generation: generation,
                        sttMilliseconds: sttMilliseconds,
                        intentMilliseconds: intentMilliseconds,
                        totalMilliseconds: totalMilliseconds
                    )
                )
            }
        }

        let commandResults = results.filter { $0.expectedOutcome == "command" }
        let clarificationResults = results.filter { $0.expectedOutcome == "clarification" }
        let commandCorrect = commandResults.filter(\.correct).count
        let clarificationCorrect = clarificationResults.filter(\.correct).count
        let highRiskFalseExecutions = results.filter {
            $0.intent == "send_message" && $0.expectedOutcome != "command"
        }.count
        let commandAccuracy = Double(commandCorrect) / Double(max(commandResults.count, 1))
        let clarificationRecall = Double(clarificationCorrect) / Double(max(clarificationResults.count, 1))
        var accuracyByLocale: [String: Double] = [:]
        for locale in Set(commandResults.map(\.locale)) {
            let localeResults = commandResults.filter { $0.locale == locale }
            accuracyByLocale[locale] = Double(localeResults.filter(\.correct).count)
                / Double(max(localeResults.count, 1))
        }

        let summary = VoiceAudioPipelineSummary(
            schemaVersion: 1,
            device: environment["KNOCK_VOICE_RESULT_DEVICE"] ?? "unspecified-ios-device",
            sampleCount: results.count,
            commandCorrect: commandCorrect,
            commandCount: commandResults.count,
            clarificationCorrect: clarificationCorrect,
            clarificationCount: clarificationResults.count,
            highRiskFalseExecutions: highRiskFalseExecutions,
            commandAccuracyByLocale: accuracyByLocale,
            sttP50Milliseconds: percentile(results.map(\.sttMilliseconds), 0.50),
            sttP95Milliseconds: percentile(results.map(\.sttMilliseconds), 0.95),
            intentP50Milliseconds: percentile(results.map(\.intentMilliseconds), 0.50),
            intentP95Milliseconds: percentile(results.map(\.intentMilliseconds), 0.95),
            totalP50Milliseconds: percentile(results.map(\.totalMilliseconds), 0.50),
            totalP95Milliseconds: percentile(results.map(\.totalMilliseconds), 0.95),
            results: results
        )
        try write(summary, package: package)

        XCTAssertGreaterThanOrEqual(
            commandAccuracy,
            package.dataset.releaseGates.minimumEndToEndCommandSemanticAccuracy
        )
        XCTAssertGreaterThanOrEqual(
            clarificationRecall,
            package.dataset.releaseGates.minimumClarificationRecall
        )
        for (locale, accuracy) in accuracyByLocale {
            XCTAssertGreaterThanOrEqual(
                accuracy,
                package.dataset.releaseGates.minimumAccuracyPerLocale,
                "\(locale) command accuracy is below the release gate"
            )
        }
        XCTAssertEqual(
            highRiskFalseExecutions,
            package.dataset.releaseGates.maximumHighRiskFalseExecutions
        )
    }

    private func evaluate(
        example: VoiceAudioDatasetV2.Example,
        row: VoiceAudioManifestRow,
        transcript: String,
        generation: Result<CommandEnvelope, Error>,
        sttMilliseconds: Int,
        intentMilliseconds: Int,
        totalMilliseconds: Int
    ) -> VoiceAudioPipelineResult {
        switch generation {
        case let .success(decoded):
            guard let envelope = try? LocalVoiceCommandPolicy.authoritativeEnvelope(from: decoded) else {
                return result(false, "validation_rejection", nil)
            }
            if example.expectedOutcome == "clarification" {
                return result(false, "clarification_false_accept", envelope)
            }
            let expectedRisk = example.riskLevel.flatMap(CommandEnvelope.RiskLevel.init(rawValue:))
            let expectedArguments = example.expectedArguments?.mapValues(JSONValue.string) ?? [:]
            let correct = envelope.intent == example.expectedIntent
                && envelope.args == expectedArguments
                && envelope.riskLevel == expectedRisk
                && envelope.needsConfirmation == example.needsConfirmation
            return result(correct, correct ? nil : "semantic_mismatch", envelope)

        case let .failure(error):
            if example.expectedOutcome == "clarification",
               LocalVoiceCommandErrorPolicy.requiresClarification(error)
            {
                return result(true, nil, nil)
            }
            let category = LocalVoiceCommandErrorPolicy.requiresClarification(error)
                ? "unexpected_clarification"
                : "model_failure"
            return result(false, category, nil)
        }

        func result(
            _ correct: Bool,
            _ category: String?,
            _ envelope: CommandEnvelope?
        ) -> VoiceAudioPipelineResult {
            VoiceAudioPipelineResult(
                exampleID: example.id,
                locale: example.locale,
                profile: row.profile,
                expectedOutcome: example.expectedOutcome,
                transcript: transcript,
                intent: envelope?.intent,
                args: envelope?.args,
                correct: correct,
                failureCategory: category,
                sttMilliseconds: sttMilliseconds,
                intentMilliseconds: intentMilliseconds,
                totalMilliseconds: totalMilliseconds
            )
        }
    }

    private func transcribe(_ url: URL, locale: Locale) async throws -> String {
        let transcriber = SystemOnDeviceSpeechTranscriber(locale: locale)
        try transcriber.reset()
        let file = try AVAudioFile(forReading: url)
        while file.framePosition < file.length {
            let remaining = min(4_096, file.length - file.framePosition)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(remaining)
            ) else { throw VoiceAudioDatasetV2Error.invalidWAV(url.lastPathComponent) }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try transcriber.append(buffer)
        }
        let completed = expectation(description: "Layer A STT \(url.lastPathComponent)")
        var recognitionResult: Result<String, Error>?
        transcriber.finish {
            recognitionResult = $0
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 20)
        return try XCTUnwrap(recognitionResult).get()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generate(
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

    private func milliseconds(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1_000).rounded())
    }

    private func percentile(_ values: [Int], _ percentile: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let ordered = values.sorted()
        let index = max(0, min(ordered.count - 1, Int(ceil(Double(ordered.count) * percentile)) - 1))
        return ordered[index]
    }

    private func write(
        _ summary: VoiceAudioPipelineSummary,
        package: VoiceAudioDatasetV2Package
    ) throws {
        let resultsDirectory = package.rootURL
            .appendingPathComponent("voice-golden-v2-generated", isDirectory: true)
            .appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
        let safeDevice = summary.device.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "-",
            options: .regularExpression
        )
        let destination = resultsDirectory.appendingPathComponent(
            "\(safeDevice)-pipeline-results.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: destination, options: .atomic)
    }
}

#endif

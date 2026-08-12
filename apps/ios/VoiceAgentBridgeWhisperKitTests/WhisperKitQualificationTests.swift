import XCTest
import WhisperKit

final class WhisperKitQualificationTests: XCTestCase {
    private struct Dataset: Decodable {
        struct Example: Decodable {
            let id: String
            let locale: String
            let text: String
        }

        let humanRecordingSubset: [String]
        let examples: [Example]

        enum CodingKeys: String, CodingKey {
            case humanRecordingSubset = "human_recording_subset"
            case examples
        }
    }

    func testWhisperKitPackageLoads() throws {
        XCTAssertFalse(String(describing: WhisperKit.self).isEmpty)
    }

    func testConfiguredFileTranscribesOnPhysicalDevice() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KNOCK_RUN_WHISPERKIT_UAT"] == "1" else {
            throw XCTSkip("Set KNOCK_RUN_WHISPERKIT_UAT=1 for the opt-in physical test")
        }

        let model = environment["KNOCK_WHISPERKIT_MODEL"] ?? "tiny"
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let datasetURL = try XCTUnwrap(
            findFile(named: "KNOCK_KNOCK_VOICE_GOLDEN_V2.json", below: documents)
        )
        let dataset = try JSONDecoder().decode(Dataset.self, from: Data(contentsOf: datasetURL))
        let requestedFile = environment["KNOCK_WHISPERKIT_AUDIO_FILE"]
            .flatMap { $0.isEmpty ? nil : $0 }
        let selectedExamples: [Dataset.Example]
        if let requestedFile {
            let requestedID = requestedFile.components(separatedBy: "__").first ?? requestedFile
            selectedExamples = dataset.examples.filter { $0.id == requestedID }
        } else {
            let coreIDs = Set(dataset.humanRecordingSubset)
            selectedExamples = dataset.examples.filter { coreIDs.contains($0.id) }
        }
        XCTAssertFalse(selectedExamples.isEmpty)

        let loadStarted = ProcessInfo.processInfo.systemUptime
        let whisper = try await WhisperKit(
            WhisperKitConfig(
                model: model,
                verbose: false,
                prewarm: true,
                load: true,
                download: true
            )
        )
        let loadMilliseconds = milliseconds(since: loadStarted)

        var localeEdits: [String: Int] = [:]
        var localeReferenceUnits: [String: Int] = [:]
        var inferenceTimes: [Int] = []
        for example in selectedExamples {
            let fileName = requestedFile ?? "\(example.id)__clean_normal.wav"
            let audioURL = try XCTUnwrap(findFile(named: fileName, below: documents))
            let inferenceStarted = ProcessInfo.processInfo.systemUptime
            let results = try await whisper.transcribe(
                audioPath: audioURL.path,
                decodeOptions: DecodingOptions(
                    language: example.locale == "en-HK" ? "en" : "zh",
                    temperature: 0,
                    usePrefillPrompt: true,
                    detectLanguage: false,
                    withoutTimestamps: true
                )
            )
            let inferenceMilliseconds = milliseconds(since: inferenceStarted)
            let transcript = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(transcript.isEmpty)
            let comparison = transcriptionDistance(
                expected: example.text,
                actual: transcript,
                locale: example.locale
            )
            localeEdits[example.locale, default: 0] += comparison.distance
            localeReferenceUnits[example.locale, default: 0] += comparison.referenceCount
            inferenceTimes.append(inferenceMilliseconds)
            print(
                "WHISPERKIT_SAMPLE model=\(model) id=\(example.id) locale=\(example.locale) "
                    + "inference_ms=\(inferenceMilliseconds) edits=\(comparison.distance) "
                    + "reference_units=\(comparison.referenceCount) transcript=\(transcript)"
            )
        }

        for locale in localeReferenceUnits.keys.sorted() {
            let units = localeReferenceUnits[locale, default: 0]
            let edits = localeEdits[locale, default: 0]
            let accuracy = units == 0 ? 0 : max(0, Double(units - edits) / Double(units))
            print("WHISPERKIT_LOCALE locale=\(locale) accuracy=\(accuracy) edits=\(edits) units=\(units)")
        }
        let sortedTimes = inferenceTimes.sorted()
        let p95Index = max(0, Int(ceil(Double(sortedTimes.count) * 0.95)) - 1)
        print(
            "WHISPERKIT_SUMMARY model=\(model) samples=\(selectedExamples.count) "
                + "load_ms=\(loadMilliseconds) p95_inference_ms=\(sortedTimes[p95Index])"
        )
    }

    private func findFile(named fileName: String, below root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let candidate as URL in enumerator where candidate.lastPathComponent == fileName {
            return candidate
        }
        return nil
    }

    private func milliseconds(since started: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - started) * 1_000).rounded())
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
}

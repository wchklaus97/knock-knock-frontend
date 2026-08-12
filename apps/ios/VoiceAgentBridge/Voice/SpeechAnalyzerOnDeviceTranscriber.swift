import AVFoundation
import Foundation
import Speech

#if compiler(>=6.2)
/// iOS 26 capability adapter used to qualify Apple's newer, fully on-device
/// transcription stack before it replaces the live iOS 15 Speech fallback.
/// It consumes a local test file without persisting or uploading new audio.
@available(iOS 26.0, *)
enum SpeechAnalyzerOnDeviceTranscriber {
    enum Mode {
        case automatic
        case speechTranscriber
        case dictationTranscriber
    }

    enum Backend: String, Codable {
        case speechTranscriber = "speech_transcriber"
        case dictationTranscriber = "dictation_transcriber"
    }

    struct Output {
        let text: String
        let backend: Backend
        let localeIdentifier: String
    }

    static func transcribe(
        audioFileURL: URL,
        locale requestedLocale: Locale,
        mode: Mode = .automatic
    ) async throws -> Output {
        if mode != .dictationTranscriber,
           SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        {
            let text = try await transcribeWithSpeechTranscriber(
                audioFileURL: audioFileURL,
                locale: locale
            )
            return Output(
                text: text,
                backend: .speechTranscriber,
                localeIdentifier: locale.identifier
            )
        }

        if mode != .speechTranscriber,
           let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale)
        {
            let text = try await transcribeWithDictationTranscriber(
                audioFileURL: audioFileURL,
                locale: locale
            )
            return Output(
                text: text,
                backend: .dictationTranscriber,
                localeIdentifier: locale.identifier
            )
        }

        throw LocalVoiceAdapterError.speechRecognizerUnavailable
    }

    private static func transcribeWithSpeechTranscriber(
        audioFileURL: URL,
        locale: Locale
    ) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await ensureAssets(for: [transcriber])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultTask = Task {
            var transcript = ""
            for try await result in transcriber.results {
                transcript.append(String(result.text.characters))
            }
            return transcript
        }

        do {
            let audioFile = try AVAudioFile(forReading: audioFileURL)
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try validate(try await resultTask.value)
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private static func transcribeWithDictationTranscriber(
        audioFileURL: URL,
        locale: Locale
    ) async throws -> String {
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        try await ensureAssets(for: [transcriber])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultTask = Task {
            var transcript = ""
            for try await result in transcriber.results {
                transcript.append(String(result.text.characters))
            }
            return transcript
        }

        do {
            let audioFile = try AVAudioFile(forReading: audioFileURL)
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try validate(try await resultTask.value)
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private static func ensureAssets(for modules: [any SpeechModule]) async throws {
        let initialStatus = await AssetInventory.status(forModules: modules)
        if initialStatus == .installed { return }
        guard initialStatus != .unsupported else {
            throw LocalVoiceAdapterError.speechRecognizerUnavailable
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw LocalVoiceAdapterError.speechRecognizerUnavailable
        }
    }

    private static func validate(_ transcript: String) throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalVoiceAdapterError.invalidModelOutput }
        return trimmed
    }
}
#endif

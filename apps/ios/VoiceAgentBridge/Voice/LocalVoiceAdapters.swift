import AVFoundation
import Foundation

/// Adapter seam for a bundled streaming ASR engine. The Phase 4 system capture uses
/// Apple's on-device Speech framework; a future WhisperKit package can conform here
/// without changing the command boundary or persisting microphone buffers.
protocol LocalSpeechTranscribing: AnyObject {
    func reset() throws
    func append(_ buffer: AVAudioPCMBuffer) throws
    func finish(completion: @escaping (Result<String, Error>) -> Void)
}

/// Adapter seam for a bundled language model (for example, Gemma). Implementations
/// return JSON bytes and callers must pass them through CommandEnvelope.decodeStrict.
protocol LocalCommandGenerating {
    func generateCommand(for transcript: String, completion: @escaping (Result<Data, Error>) -> Void)
}

protocol VoiceSynthesizing {
    func speak(_ text: String)
    func stop()
}

enum LocalVoiceAdapterError: Error, Equatable {
    case whisperKitNotLinked
    case gemmaRuntimeNotLinked
}

/// Documented build-safe placeholder; no WhisperKit dependency or model binary is
/// included in Phase 4.
final class WhisperKitTranscriberPlaceholder: LocalSpeechTranscribing {
    func reset() throws {
        throw LocalVoiceAdapterError.whisperKitNotLinked
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        throw LocalVoiceAdapterError.whisperKitNotLinked
    }

    func finish(completion: @escaping (Result<String, Error>) -> Void) {
        completion(.failure(LocalVoiceAdapterError.whisperKitNotLinked))
    }
}

/// Documented build-safe placeholder; a Gemma runtime can be injected later after
/// its artifact is selected through RollbackSafeModelSelector.
struct GemmaCommandGeneratorPlaceholder: LocalCommandGenerating {
    func generateCommand(for transcript: String, completion: @escaping (Result<Data, Error>) -> Void) {
        completion(.failure(LocalVoiceAdapterError.gemmaRuntimeNotLinked))
    }
}

/// Lightweight local TTS implementation using the system voice. It does not require
/// or download a third-party speech model.
final class SystemVoiceSynthesizer: VoiceSynthesizing {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

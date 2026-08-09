import AVFoundation
import Foundation
import Speech

#if canImport(CLiteRTLM)
import CLiteRTLM
#endif

/// Adapter seam for streaming speech recognition. The iOS 15 default is
/// Apple's on-device Speech framework. A WhisperKit implementation can conform
/// to this protocol in an iOS 16 target without changing the command boundary
/// or persisting microphone buffers.
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
    case gemmaRuntimeInitializationFailed
    case gemmaRuntimeGenerationFailed
    case modelArtifactMissing
    case invalidModelOutput
    case speechRecognizerUnavailable
}

/// Real iOS 15 speech adapter. PushToTalkVoiceCapture uses the same on-device
/// Speech framework directly so partial results and VAD can be delivered while
/// the button is held; this adapter is useful for pipelines that consume raw
/// AVAudioPCMBuffer values instead.
final class SystemOnDeviceSpeechTranscriber: LocalSpeechTranscribing {
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestText = ""
    private var completion: ((Result<String, Error>) -> Void)?
    private var didFinish = false

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    func reset() throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        completion = nil
        latestText = ""
        didFinish = false

        guard let recognizer,
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition
        else {
            throw LocalVoiceAdapterError.speechRecognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, !self.didFinish else { return }
            if let result {
                self.latestText = result.bestTranscription.formattedString
                if result.isFinal {
                    self.complete(.success(self.latestText))
                }
            } else if let error {
                self.complete(.failure(error))
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let request else {
            throw LocalVoiceAdapterError.speechRecognizerUnavailable
        }
        request.append(buffer)
    }

    func finish(completion: @escaping (Result<String, Error>) -> Void) {
        guard !didFinish else { return }
        self.completion = completion
        request?.endAudio()
        if recognitionTask == nil {
            complete(.success(latestText))
        }
    }

    private func complete(_ result: Result<String, Error>) {
        guard !didFinish else { return }
        didFinish = true
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
}

/// WhisperKit is intentionally not linked into the iOS 15 app target. The
/// current official WhisperKit package has an iOS 16 deployment floor. Keep a
/// fail-closed adapter until an iOS 16 companion target (or an approved floor
/// change) is introduced; never silently fall back to a cloud recorder.
final class UnavailableWhisperKitTranscriber: LocalSpeechTranscribing {
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

/// Kept as a source-compatible name for the existing tests and call sites.
typealias WhisperKitTranscriberPlaceholder = UnavailableWhisperKitTranscriber

#if canImport(CLiteRTLM)

/// A real on-device Gemma command generator backed by LiteRT-LM. The model
/// artifact must already have passed ModelArtifactVerifier and be selected by
/// RollbackSafeModelSelector before this object is initialized.
final class GemmaCommandGenerator: LocalCommandGenerating {
    private let runtime: LiteRTLMCommandRuntime

    init(
        modelURL: URL,
        cacheDirectory: URL? = nil,
        useGPU: Bool = true
    ) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalVoiceAdapterError.modelArtifactMissing
        }
        runtime = try LiteRTLMCommandRuntime(
            modelURL: modelURL,
            cacheDirectory: cacheDirectory,
            useGPU: useGPU
        )
    }

    func generateCommand(for transcript: String, completion: @escaping (Result<Data, Error>) -> Void) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(LocalVoiceAdapterError.invalidModelOutput))
            return
        }

        Task {
            do {
                completion(.success(try await runtime.generate(transcript: trimmed)))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

private actor LiteRTLMCommandRuntime {
    private static let systemPrompt = """
    You are a local intent parser for Knock Knock. Return only one JSON object,
    with no Markdown and no explanation. The object must contain exactly these
    CommandEnvelope v1 fields: schema_version, command_id, intent, args,
    risk_level, needs_confirmation, idempotency_key, confidence, locale, and
    timezone. Use a confidence below 0.5 when any date, time, person, amount,
    recipient, or intent is ambiguous. Never invent missing values. The backend
    is the only component allowed to execute an action.
    """

    private let modelPath: String
    private let cacheDirectory: String?
    private let useGPU: Bool
    private var engine: OpaquePointer?
    private var conversation: OpaquePointer?

    init(modelURL: URL, cacheDirectory: URL?, useGPU: Bool) throws {
        self.modelPath = modelURL.path
        self.cacheDirectory = cacheDirectory?.path
        self.useGPU = useGPU
    }

    func generate(transcript: String) throws -> Data {
        if engine == nil {
            engine = makeEngine()
            guard engine != nil else {
                throw LocalVoiceAdapterError.gemmaRuntimeInitializationFailed
            }
        }

        if conversation == nil {
            conversation = makeConversation(engine: engine!)
            guard conversation != nil else {
                throw LocalVoiceAdapterError.gemmaRuntimeInitializationFailed
            }
        }

        let messageJSON = try Self.messageJSON(text: transcript)
        guard let response = litert_lm_conversation_send_message(
            conversation!, messageJSON, nil, nil
        ) else {
            throw LocalVoiceAdapterError.gemmaRuntimeGenerationFailed
        }
        defer { litert_lm_json_response_delete(response) }

        guard let responseChars = litert_lm_json_response_get_string(response) else {
            throw LocalVoiceAdapterError.gemmaRuntimeGenerationFailed
        }
        let responseString = String(cString: responseChars)
        return try Self.extractJSONObject(from: Self.responseText(from: responseString))
    }

    private func makeEngine() -> OpaquePointer? {
        let backends = useGPU ? ["gpu", "cpu"] : ["cpu"]
        for backend in backends {
            guard let settings = litert_lm_engine_settings_create(
                modelPath, backend, nil, nil
            ) else {
                continue
            }
            defer { litert_lm_engine_settings_delete(settings) }
            litert_lm_engine_settings_set_max_num_tokens(settings, 512)
            if let cacheDirectory {
                litert_lm_engine_settings_set_cache_dir(settings, cacheDirectory)
            }
            if let engine = litert_lm_engine_create(settings) {
                return engine
            }
        }
        return nil
    }

    private func makeConversation(engine: OpaquePointer) -> OpaquePointer? {
        guard let config = litert_lm_conversation_config_create() else {
            return nil
        }
        defer { litert_lm_conversation_config_delete(config) }

        guard let systemMessageJSON = try? Self.messageContentJSON(text: Self.systemPrompt) else {
            return nil
        }
        litert_lm_conversation_config_set_system_message(config, systemMessageJSON)
        litert_lm_conversation_config_set_enable_constrained_decoding(config, false)
        return litert_lm_conversation_create(engine, config)
    }

    private static func messageContentJSON(text: String) throws -> String {
        let object: [[String: String]] = [["type": "text", "text": text]]
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw LocalVoiceAdapterError.gemmaRuntimeGenerationFailed
        }
        return string
    }

    private static func messageJSON(text: String) throws -> String {
        let object: [String: Any] = [
            "role": "user",
            "content": [["type": "text", "text": text]],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw LocalVoiceAdapterError.gemmaRuntimeGenerationFailed
        }
        return string
    }

    private static func responseText(from response: String) -> String {
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return response
        }

        if let content = object["content"] as? String {
            return content
        }
        if let content = object["content"] as? [[String: Any]] {
            let text = content.compactMap { item -> String? in
                guard item["type"] as? String == "text" else { return nil }
                return item["text"] as? String
            }.joined()
            if !text.isEmpty {
                return text
            }
        }
        return response
    }

    deinit {
        if let conversation {
            litert_lm_conversation_delete(conversation)
        }
        if let engine {
            litert_lm_engine_delete(engine)
        }
    }

    private static func extractJSONObject(from text: String) throws -> Data {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end
        else {
            throw LocalVoiceAdapterError.invalidModelOutput
        }
        let candidate = String(text[start...end])
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any]
        else {
            throw LocalVoiceAdapterError.invalidModelOutput
        }
        return data
    }
}

#else

/// Build-safe fallback for environments where the LiteRT-LM package was not
/// resolved. It fails closed and keeps the app from executing model output.
struct GemmaCommandGenerator: LocalCommandGenerating {
    init(modelURL: URL, cacheDirectory: URL? = nil, useGPU: Bool = true) throws {
        throw LocalVoiceAdapterError.gemmaRuntimeNotLinked
    }

    func generateCommand(for transcript: String, completion: @escaping (Result<Data, Error>) -> Void) {
        completion(.failure(LocalVoiceAdapterError.gemmaRuntimeNotLinked))
    }
}

#endif

/// Kept as a source-compatible name for existing injection tests. New code
/// should construct GemmaCommandGenerator with a verified model artifact.
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

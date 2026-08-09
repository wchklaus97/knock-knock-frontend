import AVFoundation
import Foundation
import Speech

/// iOS 15-compatible, on-device push-to-talk capture. Audio buffers flow directly
/// from AVAudioEngine into SFSpeechAudioBufferRecognitionRequest and are never
/// written to disk, retained as recordings, or exposed to an upload API.
final class PushToTalkVoiceCapture {
    enum State: Equatable {
        case idle
        case listening
        case stopping
    }

    enum StopReason: Equatable {
        case userReleased
        case silence
        case finalTranscript
    }

    enum CaptureError: Error, Equatable {
        case mustBeCalledOnMainThread
        case microphonePermissionDenied
        case speechPermissionDenied
        case recognizerUnavailable
        case onDeviceRecognitionUnavailable
        case invalidInputFormat
        case alreadyCapturing
        case audioSessionFailure
        case audioEngineFailure
        case recognitionFailure
    }

    struct Transcript: Equatable {
        let text: String
        let isFinal: Bool
    }

    private let audioEngine: AVAudioEngine
    private let audioSession: AVAudioSession
    private let recognizer: SFSpeechRecognizer?
    private let vadConfiguration: VoiceActivityDetector.Configuration

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var vad: VoiceActivityDetector
    private var inputTapInstalled = false
    private var transcriptHandler: ((Transcript) -> Void)?
    private var stopHandler: ((StopReason) -> Void)?
    private var errorHandler: ((CaptureError) -> Void)?

    private(set) var state: State = .idle

    init(
        locale: Locale = .current,
        vadConfiguration: VoiceActivityDetector.Configuration = .init(),
        audioEngine: AVAudioEngine = AVAudioEngine(),
        audioSession: AVAudioSession = .sharedInstance()
    ) {
        self.audioEngine = audioEngine
        self.audioSession = audioSession
        recognizer = SFSpeechRecognizer(locale: locale)
        self.vadConfiguration = vadConfiguration
        vad = VoiceActivityDetector(configuration: vadConfiguration)
    }

    static func requestPermissions(completion: @escaping (Result<Void, CaptureError>) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else {
                DispatchQueue.main.async { completion(.failure(.speechPermissionDenied)) }
                return
            }
            AVAudioSession.sharedInstance().requestRecordPermission { microphoneGranted in
                DispatchQueue.main.async {
                    completion(microphoneGranted ? .success(()) : .failure(.microphonePermissionDenied))
                }
            }
        }
    }

    func start(
        onTranscript: @escaping (Transcript) -> Void,
        onStop: @escaping (StopReason) -> Void,
        onError: @escaping (CaptureError) -> Void
    ) throws {
        guard Thread.isMainThread else { throw CaptureError.mustBeCalledOnMainThread }
        guard state == .idle else { throw CaptureError.alreadyCapturing }
        guard audioSession.recordPermission == .granted else { throw CaptureError.microphonePermissionDenied }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw CaptureError.speechPermissionDenied }
        guard let recognizer, recognizer.isAvailable else { throw CaptureError.recognizerUnavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw CaptureError.onDeviceRecognitionUnavailable }

        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw CaptureError.audioSessionFailure
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            deactivateAudioSession()
            throw CaptureError.invalidInputFormat
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation

        transcriptHandler = onTranscript
        stopHandler = onStop
        errorHandler = onError
        recognitionRequest = request
        vad = VoiceActivityDetector(configuration: vadConfiguration)

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.state != .idle else { return }
                if let result {
                    self.transcriptHandler?(
                        Transcript(text: result.bestTranscription.formattedString, isFinal: result.isFinal)
                    )
                    if result.isFinal {
                        self.finishCapture(reason: .finalTranscript)
                        return
                    }
                }
                if error != nil {
                    self.failCapture(.recognitionFailure)
                }
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self, weak request] buffer, _ in
            guard let self, let request else { return }
            request.append(buffer)

            let level = VoiceActivityDetector.levelDB(for: buffer)
            let duration = TimeInterval(buffer.frameLength) / buffer.format.sampleRate
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state == .listening else { return }
                if self.vad.process(levelDB: level, duration: duration) == .silenceLimitReached {
                    self.finishCapture(reason: .silence)
                }
            }
        }
        inputTapInstalled = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
            state = .listening
        } catch {
            cleanupCapture()
            throw CaptureError.audioEngineFailure
        }
    }

    /// Call when the press gesture ends. The latest partial transcript has already
    /// been delivered; cancellation releases in-memory audio immediately.
    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        guard state == .listening else { return }
        finishCapture(reason: .userReleased)
    }

    private func finishCapture(reason: StopReason) {
        guard state != .idle else { return }
        state = .stopping
        let completion = stopHandler
        cleanupCapture()
        completion?(reason)
    }

    private func failCapture(_ error: CaptureError) {
        guard state != .idle else { return }
        state = .stopping
        let completion = errorHandler
        cleanupCapture()
        completion?(error)
    }

    private func cleanupCapture() {
        audioEngine.stop()
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        transcriptHandler = nil
        stopHandler = nil
        errorHandler = nil
        vad.reset()
        deactivateAudioSession()
        state = .idle
    }

    private func deactivateAudioSession() {
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

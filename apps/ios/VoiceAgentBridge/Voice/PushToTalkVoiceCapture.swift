import AVFoundation
import Foundation
import Speech
import UIKit

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
        case noSpeech
        case maximumDuration
        case finalTranscript
    }

    enum AbortReason: Equatable {
        case userCancelled
        case appInactive
        case appBackgrounded
        case audioInterrupted
        case audioRouteLost
        case mediaServicesReset
    }

    enum CaptureError: Error, Equatable {
        case mustBeCalledOnMainThread
        case applicationNotActive
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

    enum RecognitionCallbackAction: Equatable {
        case ignore
        case emitPartialTranscript(Transcript)
        case finishWithFinalTranscript(Transcript, StopReason)
        case failRecognition
    }

    private struct AudioSessionSnapshot {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private let audioEngine: AVAudioEngine
    private let audioSession: AVAudioSession
    private let recognizer: SFSpeechRecognizer?
    private let vadConfiguration: VoiceActivityDetector.Configuration
    private let finalTranscriptWaitDuration: TimeInterval
    private let notificationCenter: NotificationCenter
    private let applicationIsActive: () -> Bool
    private let vadQueue = DispatchQueue(
        label: "com.knockknock.voice.capture-vad",
        qos: .userInitiated
    )

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var vad: VoiceActivityDetector
    private var activeVADCaptureID: UInt64?
    private var nextCaptureID: UInt64 = 0
    private var captureID: UInt64?
    private var inputTapInstalled = false
    private var didEndRecognitionAudio = false
    private var audioSessionSnapshot: AudioSessionSnapshot?
    private var pendingStopReason: StopReason?
    private var finalizationWorkItem: DispatchWorkItem?
    private var notificationObservers: [NSObjectProtocol] = []
    private var transcriptHandler: ((Transcript) -> Void)?
    private var stopHandler: ((StopReason) -> Void)?
    private var abortHandler: ((AbortReason) -> Void)?
    private var errorHandler: ((CaptureError) -> Void)?

    private(set) var state: State = .idle

    init(
        locale: Locale = .current,
        vadConfiguration: VoiceActivityDetector.Configuration = .init(),
        finalTranscriptWaitDuration: TimeInterval = 0.8,
        audioEngine: AVAudioEngine = AVAudioEngine(),
        audioSession: AVAudioSession = .sharedInstance(),
        notificationCenter: NotificationCenter = .default,
        applicationIsActive: @escaping () -> Bool = {
            UIApplication.shared.applicationState == .active
        }
    ) {
        self.audioEngine = audioEngine
        self.audioSession = audioSession
        recognizer = OnDeviceSpeechRecognizerFactory.make(locale: locale)
        self.vadConfiguration = vadConfiguration
        self.finalTranscriptWaitDuration = max(0, finalTranscriptWaitDuration)
        self.notificationCenter = notificationCenter
        self.applicationIsActive = applicationIsActive
        vad = VoiceActivityDetector(configuration: vadConfiguration)
    }

    deinit {
        finalizationWorkItem?.cancel()
        notificationObservers.forEach(notificationCenter.removeObserver)
        audioEngine.stop()
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        if let snapshot = audioSessionSnapshot {
            try? audioSession.setCategory(
                snapshot.category,
                mode: snapshot.mode,
                options: snapshot.options
            )
        }
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
        onAbort: @escaping (AbortReason) -> Void,
        onError: @escaping (CaptureError) -> Void
    ) throws {
        guard Thread.isMainThread else { throw CaptureError.mustBeCalledOnMainThread }
        guard state == .idle else { throw CaptureError.alreadyCapturing }
        // Lifecycle notifications only protect a capture that started while
        // the app was active. Refuse a late start after the app is already
        // inactive so no audio session can begin in the background gap.
        guard applicationIsActive() else { throw CaptureError.applicationNotActive }
        guard audioSession.recordPermission == .granted else { throw CaptureError.microphonePermissionDenied }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw CaptureError.speechPermissionDenied }
        guard let recognizer, recognizer.isAvailable else { throw CaptureError.recognizerUnavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw CaptureError.onDeviceRecognitionUnavailable }

        try activateCaptureAudioSession()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            restoreAudioSession()
            throw CaptureError.invalidInputFormat
        }

        nextCaptureID &+= 1
        let captureID = nextCaptureID
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation

        self.captureID = captureID
        transcriptHandler = onTranscript
        stopHandler = onStop
        abortHandler = onAbort
        errorHandler = onError
        recognitionRequest = request
        pendingStopReason = nil
        didEndRecognitionAudio = false
        vadQueue.sync {
            vad = VoiceActivityDetector(configuration: vadConfiguration)
            activeVADCaptureID = captureID
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async { [weak self] in
                self?.handleRecognition(result: result, error: error, captureID: captureID)
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self, weak request] buffer, _ in
            guard let self, let request else { return }
            request.append(buffer)

            let level = VoiceActivityDetector.levelDB(for: buffer)
            let duration = TimeInterval(buffer.frameLength) / buffer.format.sampleRate
            self.vadQueue.async { [weak self] in
                guard let self, self.activeVADCaptureID == captureID else { return }
                let event = self.vad.process(levelDB: level, duration: duration)
                switch event {
                case .silenceLimitReached, .noSpeechTimeoutReached, .maximumDurationReached:
                    DispatchQueue.main.async { [weak self] in
                        self?.handleVADEvent(event, captureID: captureID)
                    }
                case .none, .speechStarted:
                    break
                }
            }
        }
        inputTapInstalled = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
            state = .listening
            installLifecycleObservers(captureID: captureID)
        } catch {
            cleanupCapture(cancelRecognition: true, captureID: captureID)
            throw CaptureError.audioEngineFailure
        }
    }

    /// Gracefully ends input while allowing Speech a brief window to publish a
    /// final result. The recognition task is cancelled only after that result or
    /// the bounded finalization timeout.
    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        beginGracefulStop(reason: .userReleased)
    }

    /// Immediately invalidates capture and suppresses the normal stop callback.
    /// This path is used for explicit cancellation and all lifecycle/audio loss.
    func abort() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.abort() }
            return
        }
        abort(reason: .userCancelled)
    }

    private func handleRecognition(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        captureID: UInt64
    ) {
        let transcript = result.map {
            Transcript(text: $0.bestTranscription.formattedString, isFinal: $0.isFinal)
        }
        let action = Self.recognitionCallbackAction(
            transcript: transcript,
            hasError: error != nil,
            callbackCaptureID: captureID,
            activeCaptureID: self.captureID,
            state: state,
            pendingStopReason: pendingStopReason
        )

        switch action {
        case .ignore:
            return
        case let .emitPartialTranscript(transcript):
            transcriptHandler?(transcript)
        case let .finishWithFinalTranscript(transcript, reason):
            transcriptHandler?(
                transcript
            )
            finishAfterFinalTranscript(reason: reason, captureID: captureID)
        case .failRecognition:
            failCapture(.recognitionFailure, captureID: captureID)
        }
    }

    static func recognitionCallbackAction(
        transcript: Transcript?,
        hasError: Bool,
        callbackCaptureID: UInt64,
        activeCaptureID: UInt64?,
        state: State,
        pendingStopReason: StopReason?
    ) -> RecognitionCallbackAction {
        guard activeCaptureID == callbackCaptureID, state != .idle else { return .ignore }

        if let transcript, transcript.isFinal {
            let reason = state == .stopping
                ? pendingStopReason ?? .finalTranscript
                : .finalTranscript
            return .finishWithFinalTranscript(transcript, reason)
        }
        if hasError {
            return .failRecognition
        }
        if let transcript {
            return .emitPartialTranscript(transcript)
        }
        return .ignore
    }

    private func handleVADEvent(_ event: VoiceActivityDetector.Event, captureID: UInt64) {
        guard self.captureID == captureID, state == .listening else { return }
        switch event {
        case .silenceLimitReached:
            beginGracefulStop(reason: .silence)
        case .noSpeechTimeoutReached:
            beginGracefulStop(reason: .noSpeech)
        case .maximumDurationReached:
            beginGracefulStop(reason: .maximumDuration)
        case .none, .speechStarted:
            break
        }
    }

    private func beginGracefulStop(reason: StopReason) {
        guard state == .listening, let captureID else { return }
        state = .stopping
        pendingStopReason = reason
        stopAudioInput()
        endRecognitionAudio()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.captureID == captureID,
                  self.state == .stopping,
                  let reason = self.pendingStopReason
            else { return }
            self.completeGracefulStop(reason: reason, captureID: captureID)
        }
        finalizationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + finalTranscriptWaitDuration,
            execute: workItem
        )
    }

    private func finishAfterFinalTranscript(reason fallbackReason: StopReason, captureID: UInt64) {
        guard self.captureID == captureID else { return }
        let reason = pendingStopReason ?? fallbackReason
        if state == .listening {
            state = .stopping
            pendingStopReason = reason
            stopAudioInput()
            endRecognitionAudio()
        }
        completeGracefulStop(reason: reason, captureID: captureID)
    }

    private func completeGracefulStop(reason: StopReason, captureID: UInt64) {
        guard self.captureID == captureID, state == .stopping else { return }
        let completion = stopHandler
        cleanupCapture(cancelRecognition: true, captureID: captureID)
        completion?(reason)
    }

    private func abort(reason: AbortReason, captureID expectedCaptureID: UInt64? = nil) {
        guard state != .idle, let captureID else { return }
        guard expectedCaptureID == nil || expectedCaptureID == captureID else { return }
        state = .stopping
        let completion = abortHandler
        cleanupCapture(cancelRecognition: true, captureID: captureID)
        completion?(reason)
    }

    private func failCapture(_ error: CaptureError, captureID: UInt64) {
        guard self.captureID == captureID, state != .idle else { return }
        state = .stopping
        let completion = errorHandler
        cleanupCapture(cancelRecognition: true, captureID: captureID)
        completion?(error)
    }

    private func cleanupCapture(cancelRecognition: Bool, captureID: UInt64) {
        finalizationWorkItem?.cancel()
        finalizationWorkItem = nil
        removeLifecycleObservers()
        stopAudioInput()
        endRecognitionAudio()
        if cancelRecognition {
            recognitionTask?.cancel()
        }
        recognitionRequest = nil
        recognitionTask = nil
        transcriptHandler = nil
        stopHandler = nil
        abortHandler = nil
        errorHandler = nil
        pendingStopReason = nil
        didEndRecognitionAudio = false
        self.captureID = nil
        vadQueue.async { [weak self] in
            guard let self, self.activeVADCaptureID == captureID else { return }
            self.vad.reset()
            self.activeVADCaptureID = nil
        }
        restoreAudioSession()
        state = .idle
    }

    private func stopAudioInput() {
        audioEngine.stop()
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
    }

    private func endRecognitionAudio() {
        guard !didEndRecognitionAudio else { return }
        didEndRecognitionAudio = true
        recognitionRequest?.endAudio()
    }

    private func activateCaptureAudioSession() throws {
        audioSessionSnapshot = AudioSessionSnapshot(
            category: audioSession.category,
            mode: audioSession.mode,
            options: audioSession.categoryOptions
        )
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            restoreAudioSession()
            throw CaptureError.audioSessionFailure
        }
    }

    private func restoreAudioSession() {
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        if let snapshot = audioSessionSnapshot {
            try? audioSession.setCategory(
                snapshot.category,
                mode: snapshot.mode,
                options: snapshot.options
            )
        }
        audioSessionSnapshot = nil
    }

    private func installLifecycleObservers(captureID: UInt64) {
        removeLifecycleObservers()
        notificationObservers = [
            notificationCenter.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.abort(reason: .appInactive, captureID: captureID)
            },
            notificationCenter.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.abort(reason: .appBackgrounded, captureID: captureID)
            },
            notificationCenter.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard Self.isInterruptionBeginning(notification) else { return }
                self?.abort(reason: .audioInterrupted, captureID: captureID)
            },
            notificationCenter.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard Self.isRouteLoss(notification) else { return }
                self?.abort(reason: .audioRouteLost, captureID: captureID)
            },
            notificationCenter.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.abort(reason: .mediaServicesReset, captureID: captureID)
            },
        ]
    }

    private func removeLifecycleObservers() {
        notificationObservers.forEach(notificationCenter.removeObserver)
        notificationObservers.removeAll()
    }

    private static func isInterruptionBeginning(_ notification: Notification) -> Bool {
        guard let rawValue = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
              let type = AVAudioSession.InterruptionType(rawValue: rawValue)
        else { return false }
        return type == .began
    }

    private static func isRouteLoss(_ notification: Notification) -> Bool {
        guard let rawValue = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue)
        else { return false }
        return reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory
    }
}

protocol PushToTalkVoiceCapturing: AnyObject {
    func start(
        onTranscript: @escaping (PushToTalkVoiceCapture.Transcript) -> Void,
        onStop: @escaping (PushToTalkVoiceCapture.StopReason) -> Void,
        onAbort: @escaping (PushToTalkVoiceCapture.AbortReason) -> Void,
        onError: @escaping (PushToTalkVoiceCapture.CaptureError) -> Void
    ) throws

    func stop()
    func abort()
}

extension PushToTalkVoiceCapture: PushToTalkVoiceCapturing {}

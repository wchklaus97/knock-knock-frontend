import AVFoundation
import Combine
import Foundation
import Speech

private final class VoiceGenerationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var pendingResult: Result<Data, Error>?
    private var isResolved = false

    func value(
        starting operation: (@escaping (Result<Data, Error>) -> Void) -> Void
    ) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                var immediateResult: Result<Data, Error>?
                var shouldStart = false

                lock.lock()
                if isResolved {
                    immediateResult = pendingResult ?? .failure(CancellationError())
                    pendingResult = nil
                } else {
                    self.continuation = continuation
                    shouldStart = true
                }
                lock.unlock()

                if let immediateResult {
                    continuation.resume(with: immediateResult)
                } else if shouldStart {
                    operation { [weak self] result in
                        self?.resolve(result)
                    }
                }
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<Data, Error>) {
        var continuationToResume: CheckedContinuation<Data, Error>?

        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        if let continuation {
            continuationToResume = continuation
            self.continuation = nil
        } else {
            pendingResult = result
        }
        lock.unlock()

        continuationToResume?.resume(with: result)
    }
}

/// Main-thread coordinator for the user-visible push-to-talk flow. It owns no
/// executable action: capture produces a transcript, the local model produces
/// an envelope, and only a current, uncancelled operation may submit it.
@MainActor
final class LocalVoiceCommandController: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermissions
        case listening
        case processing
        case clarificationRequired
        case submitted(String)
        case failed(String)
    }

    typealias PermissionStatusProvider = () -> Bool
    typealias PermissionRequester = (@escaping (Result<Void, PushToTalkVoiceCapture.CaptureError>) -> Void) -> Void

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""

    private let capture: PushToTalkVoiceCapturing
    private let generator: LocalCommandGenerating
    private let submit: @Sendable (CommandEnvelope) async throws -> CommandResponse
    private let synthesizer: VoiceSynthesizing
    private let permissionsAreGranted: PermissionStatusProvider
    private let requestPermissions: PermissionRequester

    private var pressActive = false
    private var nextSessionID: UInt64 = 0
    private var activeSessionID: UInt64?
    private var processingTask: Task<Void, Never>?
    private var generationWaiter: VoiceGenerationWaiter?

    init(
        generator: LocalCommandGenerating,
        submit: @escaping @Sendable (CommandEnvelope) async throws -> CommandResponse,
        capture: PushToTalkVoiceCapturing = PushToTalkVoiceCapture(),
        synthesizer: VoiceSynthesizing = SystemVoiceSynthesizer(),
        permissionsAreGranted: @escaping PermissionStatusProvider = {
            SFSpeechRecognizer.authorizationStatus() == .authorized
                && AVAudioSession.sharedInstance().recordPermission == .granted
        },
        requestPermissions: @escaping PermissionRequester = { completion in
            PushToTalkVoiceCapture.requestPermissions(completion: completion)
        }
    ) {
        self.capture = capture
        self.generator = generator
        self.submit = submit
        self.synthesizer = synthesizer
        self.permissionsAreGranted = permissionsAreGranted
        self.requestPermissions = requestPermissions
    }

    deinit {
        generationWaiter?.cancel()
        processingTask?.cancel()
        capture.abort()
        synthesizer.stop()
    }

    /// Begins a new recording. Speech output is stopped first so it cannot feed
    /// the microphone or compete with the capture audio session.
    func start() {
        guard canStart else { return }
        cancelProcessing()
        capture.abort()
        synthesizer.stop()

        nextSessionID &+= 1
        let sessionID = nextSessionID
        activeSessionID = sessionID
        pressActive = true
        transcript = ""

        if permissionsAreGranted() {
            startCapture(sessionID: sessionID)
            return
        }

        state = .requestingPermissions
        requestPermissions { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrent(sessionID),
                      self.state == .requestingPermissions,
                      self.pressActive
                else { return }

                switch result {
                case .success:
                    self.startCapture(sessionID: sessionID)
                case let .failure(error):
                    self.finishWithFailure(error, sessionID: sessionID)
                }
            }
        }
    }

    /// Gracefully ends recording. Capture owns the short final-transcript wait;
    /// inference does not start until its stop callback arrives.
    func stop() {
        pressActive = false
        switch state {
        case .listening:
            capture.stop()
        case .requestingPermissions:
            abort()
        default:
            break
        }
    }

    func cancel() {
        abort()
    }

    /// Invalidates permission, capture, inference, and API work. All callbacks
    /// carry a session ID, so even a non-cooperative dependency cannot submit or
    /// publish state after this returns.
    func abort() {
        activeSessionID = nil
        pressActive = false
        cancelProcessing()
        capture.abort()
        synthesizer.stop()
        state = .idle
        transcript = ""
    }

    private func startCapture(sessionID: UInt64) {
        guard isCurrent(sessionID), pressActive else { return }
        state = .listening
        do {
            try capture.start(
                onTranscript: { [weak self] partial in
                    guard let self, self.isCurrent(sessionID), self.state == .listening else { return }
                    self.transcript = partial.text
                },
                onStop: { [weak self] _ in
                    guard let self else { return }
                    self.processLatestTranscript(sessionID: sessionID)
                },
                onAbort: { [weak self] _ in
                    guard let self else { return }
                    self.finishAfterCaptureAbort(sessionID: sessionID)
                },
                onError: { [weak self] error in
                    guard let self else { return }
                    self.finishWithFailure(error, sessionID: sessionID)
                }
            )
        } catch {
            finishWithFailure(error, sessionID: sessionID)
        }
    }

    private func processLatestTranscript(sessionID: UInt64) {
        guard isCurrent(sessionID), state == .listening else { return }
        pressActive = false

        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            finishWithClarification(sessionID: sessionID)
            return
        }

        state = .processing
        let waiter = VoiceGenerationWaiter()
        generationWaiter = waiter
        let generator = self.generator
        let submit = self.submit

        processingTask = Task { @MainActor [weak self] in
            do {
                let data = try await waiter.value { completion in
                    generator.generateCommand(for: text, completion: completion)
                }
                try Task.checkCancellation()
                guard self?.isCurrent(sessionID) == true else { return }

                let envelope: CommandEnvelope
                do {
                    let decoded = try CommandEnvelope.decodeStrict(from: data)
                    envelope = try LocalVoiceCommandPolicy.authoritativeEnvelope(from: decoded)
                } catch {
                    self?.finishWithClarification(sessionID: sessionID)
                    return
                }

                try Task.checkCancellation()
                guard self?.isCurrent(sessionID) == true else { return }
                let response = try await submit(envelope)
                try Task.checkCancellation()
                guard self?.isCurrent(sessionID) == true else { return }
                self?.finishWithSubmission(response, sessionID: sessionID)
            } catch is CancellationError {
                return
            } catch {
                guard self?.isCurrent(sessionID) == true else { return }
                self?.finishWithFailure(error, sessionID: sessionID)
            }
        }
    }

    private func finishWithClarification(sessionID: UInt64) {
        guard isCurrent(sessionID) else { return }
        activeSessionID = nil
        processingTask = nil
        generationWaiter = nil
        state = .clarificationRequired
        synthesizer.speak("Could you clarify that?")
    }

    private func finishWithSubmission(_ response: CommandResponse, sessionID: UInt64) {
        guard isCurrent(sessionID) else { return }
        activeSessionID = nil
        processingTask = nil
        generationWaiter = nil
        state = .submitted(response.command_id)
    }

    private func finishWithFailure(_ error: Error, sessionID: UInt64) {
        guard isCurrent(sessionID) else { return }
        activeSessionID = nil
        pressActive = false
        cancelProcessing()
        capture.abort()
        synthesizer.stop()
        state = .failed(error.localizedDescription)
    }

    private func finishAfterCaptureAbort(sessionID: UInt64) {
        guard isCurrent(sessionID) else { return }
        activeSessionID = nil
        pressActive = false
        cancelProcessing()
        synthesizer.stop()
        state = .idle
        transcript = ""
    }

    private func cancelProcessing() {
        generationWaiter?.cancel()
        processingTask?.cancel()
        generationWaiter = nil
        processingTask = nil
    }

    private func isCurrent(_ sessionID: UInt64) -> Bool {
        activeSessionID == sessionID
    }

    private var canStart: Bool {
        switch state {
        case .idle, .clarificationRequired, .submitted, .failed:
            return true
        case .requestingPermissions, .listening, .processing:
            return false
        }
    }
}

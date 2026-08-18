import AVFoundation
import Combine
import Foundation
import Speech

final class VoiceGenerationWaiter: @unchecked Sendable {
    private enum OperationPhase {
        case idle
        case starting
        case started
        case finished
    }

    private let lock = NSLock()
    private let beforeStartingOperation: () -> Void
    private var continuation: CheckedContinuation<Data, Error>?
    private var pendingResult: Result<Data, Error>?
    private var isResolved = false
    private var operationPhase = OperationPhase.idle
    private var cancellationRequested = false
    private var cancellationAction: (() -> Void)?
    private var cancellationActionInvoked = false

    init(beforeStartingOperation: @escaping () -> Void = {}) {
        self.beforeStartingOperation = beforeStartingOperation
    }

    func value(
        starting operation: (@escaping (Result<Data, Error>) -> Void) -> Void,
        onCancel cancellationAction: @escaping () -> Void
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
                    self.cancellationAction = cancellationAction
                    operationPhase = .starting
                    shouldStart = true
                }
                lock.unlock()

                if let immediateResult {
                    continuation.resume(with: immediateResult)
                } else if shouldStart {
                    beforeStartingOperation()
                    operation { [weak self] result in
                        self?.resolveFromOperation(result)
                    }
                    finishStartingOperation()
                }
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    func cancel() {
        fail(with: CancellationError())
    }

    func fail(with error: Error) {
        var actionToInvoke: (() -> Void)?
        var continuationToResume: CheckedContinuation<Data, Error>?

        lock.lock()
        cancellationRequested = true
        switch operationPhase {
        case .idle:
            operationPhase = .finished
            cancellationAction = nil
        case .starting:
            break
        case .started:
            actionToInvoke = takeCancellationActionLocked()
        case .finished:
            break
        }
        continuationToResume = resolveLocked(.failure(error))
        lock.unlock()

        actionToInvoke?()
        continuationToResume?.resume(with: .failure(error))
    }

    private func finishStartingOperation() {
        var actionToInvoke: (() -> Void)?

        lock.lock()
        if operationPhase == .starting {
            operationPhase = .started
            if cancellationRequested {
                actionToInvoke = takeCancellationActionLocked()
            }
        }
        lock.unlock()

        actionToInvoke?()
    }

    private func resolveFromOperation(_ result: Result<Data, Error>) {
        let continuationToResume: CheckedContinuation<Data, Error>?

        lock.lock()
        operationPhase = .finished
        cancellationAction = nil
        continuationToResume = resolveLocked(result)
        lock.unlock()

        continuationToResume?.resume(with: result)
    }

    private func takeCancellationActionLocked() -> (() -> Void)? {
        guard !cancellationActionInvoked else { return nil }
        cancellationActionInvoked = true
        defer { cancellationAction = nil }
        return cancellationAction
    }

    private func resolveLocked(
        _ result: Result<Data, Error>
    ) -> CheckedContinuation<Data, Error>? {
        guard !isResolved else { return nil }
        isResolved = true
        if let continuation {
            self.continuation = nil
            return continuation
        }
        pendingResult = result
        return nil
    }
}

enum LocalVoiceCommandControllerError: LocalizedError, Equatable {
    case generationTimedOut

    var errorDescription: String? {
        switch self {
        case .generationTimedOut:
            return "Voice command generation timed out."
        }
    }
}

/// Main-thread coordinator for the user-visible push-to-talk flow. It owns no
/// executable action: capture produces a transcript, the local model produces
/// an envelope, and only a current, uncancelled operation may submit it.
@MainActor
final class LocalVoiceCommandController: ObservableObject {
    enum State: Equatable {
        enum Clarification: Equatable {
            case generic
            case missingSendRecipient
            case missingSendBody
            case selectAgent
            case agentNotListening
        }

        case idle
        case requestingPermissions
        case listening
        case processing
        case clarificationRequired(Clarification)
        case submitted(String)
        case asked(String)
        case failed(String)
    }

    typealias PermissionStatusProvider = () -> Bool
    typealias PermissionRequester = (@escaping (Result<Void, PushToTalkVoiceCapture.CaptureError>) -> Void) -> Void

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var isFollowUpListen = false
    @Published private(set) var followUpListenIsBody = false

    private let capture: PushToTalkVoiceCapturing
    private let generator: LocalCommandGenerating
    private let submit: @Sendable (CommandEnvelope) async throws -> CommandResponse
    private let askTarget: () -> VoiceAskTarget?
    private let submitAsk: (@Sendable (String) async throws -> PhoneAskResponse)?
    private let synthesizer: VoiceSynthesizing
    private let operationIsAllowed: () -> Bool
    private let permissionsAreGranted: PermissionStatusProvider
    private let requestPermissions: PermissionRequester
    private let generationTimeoutNanoseconds: UInt64
    private let followUpListenDelayNanoseconds: UInt64

    private var pressActive = false
    private var didAutoListenForPendingSlot = false
    private var nextSessionID: UInt64 = 0
    private var activeSessionID: UInt64?
    private var processingTask: Task<Void, Never>?
    private var generationWaiter: VoiceGenerationWaiter?
    private var generationTimeoutTask: Task<Void, Never>?
    private var finalTranscript = ""
    private var pendingSlot: PendingSlot?
    private var followUpStartRetries = 0

    private enum PendingSlot: Equatable {
        case sendMessageRecipient(body: String)
        case sendMessageBody(recipient: String)
    }

    init(
        generator: LocalCommandGenerating,
        submit: @escaping @Sendable (CommandEnvelope) async throws -> CommandResponse,
        capture: PushToTalkVoiceCapturing = PushToTalkVoiceCapture(),
        synthesizer: VoiceSynthesizing = SystemVoiceSynthesizer(),
        askTarget: @escaping () -> VoiceAskTarget? = { nil },
        submitAsk: (@Sendable (String) async throws -> PhoneAskResponse)? = nil,
        operationIsAllowed: @escaping () -> Bool = { true },
        permissionsAreGranted: @escaping PermissionStatusProvider = {
            SFSpeechRecognizer.authorizationStatus() == .authorized
                && AVAudioSession.sharedInstance().recordPermission == .granted
        },
        requestPermissions: @escaping PermissionRequester = { completion in
            PushToTalkVoiceCapture.requestPermissions(completion: completion)
        },
        generationTimeoutNanoseconds: UInt64 = 15_000_000_000,
        followUpListenDelayNanoseconds: UInt64 = 400_000_000
    ) {
        self.capture = capture
        self.generator = generator
        self.submit = submit
        self.askTarget = askTarget
        self.submitAsk = submitAsk
        self.synthesizer = synthesizer
        self.operationIsAllowed = operationIsAllowed
        self.permissionsAreGranted = permissionsAreGranted
        self.requestPermissions = requestPermissions
        self.generationTimeoutNanoseconds = generationTimeoutNanoseconds
        self.followUpListenDelayNanoseconds = followUpListenDelayNanoseconds
    }

    deinit {
        generationTimeoutTask?.cancel()
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
        isFollowUpListen = false
        followUpListenIsBody = false
        transcript = ""
        finalTranscript = ""

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
    /// Hands-free follow-up listen is owned by VAD, so a dock release must not
    /// cut it off while the user answers the person question.
    func stop() {
        if isFollowUpListen {
            return
        }
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

    /// Home keeps `.submitted` after POST. Once the backend command is terminal
    /// or released, return the dock to idle without stopping in-flight speech.
    func acknowledgeSettledCommand() {
        switch state {
        case .submitted, .asked:
            state = .idle
        default:
            return
        }
    }

    /// Invalidates permission, capture, inference, and API work. All callbacks
    /// carry a session ID, so even a non-cooperative dependency cannot submit or
    /// publish state after this returns.
    func abort() {
        activeSessionID = nil
        pressActive = false
        isFollowUpListen = false
        clearPendingSlot()
        cancelProcessing()
        capture.abort()
        synthesizer.stop()
        state = .idle
        transcript = ""
        finalTranscript = ""
    }

    private func startCapture(sessionID: UInt64) {
        guard isCurrent(sessionID), pressActive || isFollowUpListen else { return }
        state = .listening
        do {
            try capture.start(
                onTranscript: { [weak self] transcript in
                    guard let self, self.isCurrent(sessionID), self.state == .listening else { return }
                    self.transcript = transcript.text
                    if transcript.isFinal {
                        self.finalTranscript = transcript.text
                    }
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
                    self.finishCaptureError(error, sessionID: sessionID)
                }
            )
        } catch {
            finishWithFailure(error, sessionID: sessionID)
        }
    }

    private func processLatestTranscript(sessionID: UInt64) {
        guard isCurrent(sessionID), state == .listening else { return }
        pressActive = false
        isFollowUpListen = false
        followUpListenIsBody = false

        let text = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pending = pendingSlot {
            let followUpText = text.isEmpty
                ? transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                : text
            handleFollowUp(followUpText, pending: pending, sessionID: sessionID)
            return
        }

        guard !text.isEmpty else {
            finishWithClarification(sessionID: sessionID, kind: .generic)
            return
        }

        if shouldUseLocalCommand(for: text) {
            beginGeneration(for: text, sessionID: sessionID)
            return
        }
        if submitAsk != nil {
            if askTarget() != nil {
                beginAsk(for: text, sessionID: sessionID)
            } else {
                finishWithClarification(
                    sessionID: sessionID,
                    kind: .selectAgent,
                    speak: "Select an agent first."
                )
            }
            return
        }
        beginGeneration(for: text, sessionID: sessionID)
    }

    private func shouldUseLocalCommand(for text: String) -> Bool {
        LocalVoiceUtterancePreflight.prefersLocalCommandPath(for: text)
    }

    private func handleFollowUp(
        _ text: String,
        pending: PendingSlot,
        sessionID: UInt64
    ) {
        guard !text.isEmpty else {
            finishFollowUpUnresolved(sessionID: sessionID)
            return
        }

        if shouldReplacePending(with: text) {
            clearPendingSlot()
            beginGeneration(for: text, sessionID: sessionID)
            return
        }

        switch pending {
        case let .sendMessageRecipient(body):
            guard let recipient = LocalVoiceArgumentGrounder.fillNamedRecipient(from: text) else {
                finishFollowUpUnresolved(sessionID: sessionID)
                return
            }
            if body.isEmpty {
                pendingSlot = .sendMessageBody(recipient: recipient)
                didAutoListenForPendingSlot = false
                followUpStartRetries = 0
                finishWithClarification(
                    sessionID: sessionID,
                    kind: .missingSendBody,
                    speak: "What should I say?",
                    autoListenOnce: true
                )
                return
            }
            clearPendingSlot()
            beginGeneration(
                for: LocalVoiceArgumentGrounder.reconstructedSendTranscript(
                    recipient: recipient,
                    body: body
                ),
                sessionID: sessionID
            )
        case let .sendMessageBody(recipient):
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else {
                finishFollowUpUnresolved(sessionID: sessionID)
                return
            }
            clearPendingSlot()
            beginGeneration(
                for: LocalVoiceArgumentGrounder.reconstructedSendTranscript(
                    recipient: recipient,
                    body: body
                ),
                sessionID: sessionID
            )
        }
    }

    private func shouldReplacePending(with text: String) -> Bool {
        let intent: String?
        do {
            intent = try LocalVoiceUtterancePreflight.intentHint(for: text)
        } catch {
            return false
        }
        switch intent {
        case "search_history", "create_reminder", "create_draft":
            return true
        case "send_message":
            return LocalVoiceArgumentGrounder.hasCompleteSendMessage(from: text)
        default:
            return false
        }
    }

    private func beginGeneration(for text: String, sessionID: UInt64) {
        state = .processing
        let waiter = VoiceGenerationWaiter()
        generationWaiter = waiter
        let generator = self.generator
        let submit = self.submit
        startGenerationTimeout(waiter: waiter)

        processingTask = Task { @MainActor [weak self] in
            do {
                let data = try await waiter.value { completion in
                    generator.generateCommand(for: text, completion: completion)
                } onCancel: {
                    generator.cancelGeneration()
                }
                self?.clearGenerationTimeout()
                self?.generationWaiter = nil
                try Task.checkCancellation()
                guard self?.isCurrent(sessionID) == true else { return }

                let envelope: CommandEnvelope
                do {
                    let decoded = try CommandEnvelope.decodeStrict(from: data)
                    envelope = try LocalVoiceCommandPolicy.authoritativeEnvelope(from: decoded)
                } catch {
                    self?.finishGenerationClarification(sessionID: sessionID)
                    return
                }

                try Task.checkCancellation()
                guard self?.isCurrent(sessionID) == true else { return }
                let response = try await submit(envelope)
                try Task.checkCancellation()
                guard self?.isCurrent(sessionID) == true else { return }
                self?.finishWithSubmission(response, sessionID: sessionID)
            } catch is CancellationError {
                self?.clearGenerationTimeout()
                return
            } catch {
                self?.clearGenerationTimeout()
                guard self?.isCurrent(sessionID) == true else { return }
                if LocalVoiceCommandErrorPolicy.requiresClarification(error) {
                    self?.finishGenerationClarification(error, sessionID: sessionID)
                } else {
                    self?.finishWithFailure(error, sessionID: sessionID)
                }
            }
        }
    }

    private func beginAsk(for text: String, sessionID: UInt64) {
        guard let submitAsk, let target = askTarget() else {
            finishWithClarification(
                sessionID: sessionID,
                kind: .selectAgent,
                speak: "Select an agent first."
            )
            return
        }
        state = .processing
        processingTask = Task { @MainActor [weak self] in
            do {
                let response = try await submitAsk(text)
                try Task.checkCancellation()
                guard self?.isCurrent(sessionID) == true else { return }
                self?.finishWithAsk(response, label: target.label, sessionID: sessionID)
            } catch is CancellationError {
                return
            } catch {
                guard self?.isCurrent(sessionID) == true else { return }
                if (error as? APIClientError)?.isAgentNotListening == true {
                    self?.finishWithClarification(
                        sessionID: sessionID,
                        kind: .agentNotListening,
                        speak: "\(target.label) is not listening."
                    )
                    return
                }
                self?.finishWithFailure(error, sessionID: sessionID)
            }
        }
    }

    private func finishGenerationClarification(
        _ error: Error? = nil,
        sessionID: UInt64
    ) {
        if pendingSlot != nil {
            finishFollowUpUnresolved(sessionID: sessionID)
            return
        }
        if case let .clarificationRequired(.missingSendRecipient(body)) =
            error as? LocalCommandEnvelopeCanonicalizerError
        {
            pendingSlot = .sendMessageRecipient(body: body)
            finishWithClarification(
                sessionID: sessionID,
                kind: .missingSendRecipient,
                speak: "Who should I send this to?",
                autoListenOnce: true
            )
            return
        }
        if case let .clarificationRequired(.missingSendBody(recipient)) =
            error as? LocalCommandEnvelopeCanonicalizerError
        {
            pendingSlot = .sendMessageBody(recipient: recipient)
            finishWithClarification(
                sessionID: sessionID,
                kind: .missingSendBody,
                speak: "What should I say?",
                autoListenOnce: true
            )
            return
        }
        finishWithClarification(sessionID: sessionID, kind: .generic)
    }

    private func finishFollowUpUnresolved(sessionID: UInt64) {
        guard isCurrent(sessionID) else { return }
        activeSessionID = nil
        pressActive = false
        isFollowUpListen = false
        followUpListenIsBody = false
        clearGenerationTimeout()
        processingTask = nil
        generationWaiter = nil
        state = .clarificationRequired(pendingClarificationKind)
    }

    private func finishWithClarification(
        sessionID: UInt64,
        kind: State.Clarification,
        speak prompt: String = "I didn't catch that.",
        autoListenOnce: Bool = false
    ) {
        guard isCurrent(sessionID) else { return }
        clearGenerationTimeout()
        processingTask = nil
        generationWaiter = nil
        state = .clarificationRequired(kind)
        if autoListenOnce {
            synthesizer.speak(prompt) { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.handleClarificationSpeechFinished(result, sessionID: sessionID)
                }
            }
            return
        }
        activeSessionID = nil
        synthesizer.speak(prompt)
    }

    private func handleClarificationSpeechFinished(
        _ result: VoiceSynthesisResult,
        sessionID: UInt64
    ) {
        guard isCurrent(sessionID),
              result == .finished,
              pendingSlot != nil,
              !didAutoListenForPendingSlot,
              isPendingSlotClarification
        else { return }

        didAutoListenForPendingSlot = true
        followUpStartRetries = 0
        isFollowUpListen = true
        followUpListenIsBody = pendingSlotIsBody
        transcript = ""
        finalTranscript = ""
        synthesizer.stop()
        startFollowUpCapture(sessionID: sessionID)
    }

    private func startFollowUpCapture(sessionID: UInt64) {
        let delay = followUpListenDelayNanoseconds
        guard delay > 0 else {
            startCapture(sessionID: sessionID)
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self,
                  self.isCurrent(sessionID),
                  self.pendingSlot != nil,
                  self.isPendingSlotClarification
            else { return }
            self.isFollowUpListen = true
            self.followUpListenIsBody = self.pendingSlotIsBody
            self.startCapture(sessionID: sessionID)
        }
    }

    private func finishCaptureError(
        _ error: Error,
        sessionID: UInt64
    ) {
        if pendingSlot != nil, isRecoverableFollowUpCaptureError(error) {
            if retryFollowUpListen(sessionID: sessionID) {
                return
            }
            finishFollowUpUnresolved(sessionID: sessionID)
            return
        }
        finishWithFailure(error, sessionID: sessionID)
    }

    private func isRecoverableFollowUpCaptureError(_ error: Error) -> Bool {
        let captureError = error as? PushToTalkVoiceCapture.CaptureError
        return captureError == .noSpeechDetected || captureError == .recognitionFailure
    }

    private func retryFollowUpListen(sessionID: UInt64) -> Bool {
        guard isCurrent(sessionID),
              pendingSlot != nil,
              followUpStartRetries < 1
        else { return false }

        followUpStartRetries += 1
        isFollowUpListen = true
        followUpListenIsBody = pendingSlotIsBody
        transcript = ""
        finalTranscript = ""
        state = .clarificationRequired(pendingClarificationKind)
        startFollowUpCapture(sessionID: sessionID)
        return true
    }

    private func finishWithSubmission(_ response: CommandResponse, sessionID: UInt64) {
        guard isCurrent(sessionID) else { return }
        activeSessionID = nil
        clearPendingSlot()
        clearGenerationTimeout()
        processingTask = nil
        generationWaiter = nil
        state = .submitted(response.command_id)
    }

    private func finishWithAsk(
        _ response: PhoneAskResponse,
        label: String,
        sessionID: UInt64
    ) {
        guard isCurrent(sessionID) else { return }
        activeSessionID = nil
        clearPendingSlot()
        clearGenerationTimeout()
        processingTask = nil
        generationWaiter = nil
        let spokenLabel = (response.agent_label?.isEmpty == false)
            ? (response.agent_label ?? label)
            : label
        state = .asked(spokenLabel)
        synthesizer.speak("Asked \(spokenLabel).")
    }

    private func finishWithFailure(_ error: Error, sessionID: UInt64) {
        guard isCurrent(sessionID) else { return }
        activeSessionID = nil
        pressActive = false
        isFollowUpListen = false
        clearPendingSlot()
        cancelProcessing()
        capture.abort()
        synthesizer.stop()
        state = .failed(error.localizedDescription)
    }

    private func finishAfterCaptureAbort(sessionID: UInt64) {
        guard isCurrent(sessionID) else { return }
        activeSessionID = nil
        pressActive = false
        isFollowUpListen = false
        clearPendingSlot()
        cancelProcessing()
        synthesizer.stop()
        state = .idle
        transcript = ""
        finalTranscript = ""
    }

    private func startGenerationTimeout(waiter: VoiceGenerationWaiter) {
        clearGenerationTimeout()
        let timeoutNanoseconds = generationTimeoutNanoseconds
        guard timeoutNanoseconds > 0 else { return }
        generationTimeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            waiter.fail(with: LocalVoiceCommandControllerError.generationTimedOut)
        }
    }

    private func clearGenerationTimeout() {
        generationTimeoutTask?.cancel()
        generationTimeoutTask = nil
    }

    private func cancelProcessing() {
        clearGenerationTimeout()
        generationWaiter?.cancel()
        processingTask?.cancel()
        generationWaiter = nil
        processingTask = nil
    }

    private func clearPendingSlot() {
        pendingSlot = nil
        didAutoListenForPendingSlot = false
        followUpStartRetries = 0
        followUpListenIsBody = false
    }

    private var pendingSlotIsBody: Bool {
        if case .sendMessageBody = pendingSlot { return true }
        return false
    }

    private var isPendingSlotClarification: Bool {
        switch state {
        case .clarificationRequired(.missingSendRecipient),
             .clarificationRequired(.missingSendBody):
            return true
        default:
            return false
        }
    }

    private var pendingClarificationKind: State.Clarification {
        switch pendingSlot {
        case .sendMessageRecipient:
            return .missingSendRecipient
        case .sendMessageBody:
            return .missingSendBody
        case nil:
            return .generic
        }
    }

    private func isCurrent(_ sessionID: UInt64) -> Bool {
        activeSessionID == sessionID && operationIsAllowed()
    }

    private var canStart: Bool {
        guard operationIsAllowed() else { return false }
        switch state {
        case .idle, .clarificationRequired, .submitted, .asked, .failed:
            return true
        case .requestingPermissions, .listening, .processing:
            return false
        }
    }
}

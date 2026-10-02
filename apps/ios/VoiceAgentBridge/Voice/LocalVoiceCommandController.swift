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
    case deliveryUnconfirmed

    var errorDescription: String? {
        switch self {
        case .generationTimedOut:
            return "Voice command generation timed out."
        case .deliveryUnconfirmed:
            return "Delivery could not be confirmed. Please try again."
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
        case asking(String)
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
    private var resolvedAskTargetForTurn: VoiceAskTarget?
    private let submitAsk: (
        @Sendable (String, VoiceAskTarget, String) async throws -> PhoneAskSubmissionOutcome
    )?
    private let streamAskResponses: (
        @Sendable (
            PhoneAskResponse,
            @escaping @Sendable (String) async -> Void
        ) async throws -> Bool
    )?
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
    private var activeClientTurnID: String?
    private var turnOutcomeOwner: TurnOutcomeOwner?
    private var nextCaptureAttemptID: UInt64 = 0
    private var activeCaptureAttemptID: UInt64?
    private var nextClarificationSpeechID: UInt64 = 0
    private var activeClarificationSpeechID: UInt64?
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

    private enum TurnPhase {
        case requestingPermissions
        case capturing
        case processing
        case requestInFlight
        case deliveryUnknown
        case reconciling
        case accepted
        case awaitingClarification
        case terminal
    }

    private enum TerminalOutcome {
        case clarification
        case submitted
        case asked
        case failed
        case aborted
    }

    private struct TurnOutcomeOwner {
        let sessionID: UInt64
        let clientTurnID: String
        var phase: TurnPhase
        var terminalOutcome: TerminalOutcome?
        var terminalSpeechClaimed = false
        var acknowledgementSpeechClaimed = false
    }

    init(
        generator: LocalCommandGenerating,
        submit: @escaping @Sendable (CommandEnvelope) async throws -> CommandResponse,
        capture: PushToTalkVoiceCapturing = PushToTalkVoiceCapture(),
        synthesizer: VoiceSynthesizing = SystemVoiceSynthesizer(),
        askTarget: @escaping () -> VoiceAskTarget? = { nil },
        submitAsk: (
            @Sendable (String, VoiceAskTarget, String) async throws -> PhoneAskResponse
        )? = nil,
        submitAskOutcome: (
            @Sendable (String, VoiceAskTarget, String) async throws -> PhoneAskSubmissionOutcome
        )? = nil,
        streamAskResponses: (
            @Sendable (
                PhoneAskResponse,
                @escaping @Sendable (String) async -> Void
            ) async throws -> Bool
        )? = nil,
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
        if let submitAskOutcome {
            self.submitAsk = submitAskOutcome
        } else if let submitAsk {
            self.submitAsk = { transcript, target, clientTurnID in
                .accepted(try await submitAsk(transcript, target, clientTurnID))
            }
        } else {
            self.submitAsk = nil
        }
        self.streamAskResponses = streamAskResponses
        self.synthesizer = synthesizer
        self.operationIsAllowed = operationIsAllowed
        self.permissionsAreGranted = permissionsAreGranted
        self.requestPermissions = requestPermissions
        self.generationTimeoutNanoseconds = generationTimeoutNanoseconds
        self.followUpListenDelayNanoseconds = followUpListenDelayNanoseconds
    }

#if DEBUG
    /// Source-compatible test adapter. Production callers receive the frozen
    /// target and stable client turn ID together.
    convenience init(
        generator: LocalCommandGenerating,
        submit: @escaping @Sendable (CommandEnvelope) async throws -> CommandResponse,
        capture: PushToTalkVoiceCapturing = PushToTalkVoiceCapture(),
        synthesizer: VoiceSynthesizing = SystemVoiceSynthesizer(),
        askTarget: @escaping () -> VoiceAskTarget? = { nil },
        submitAsk: (@Sendable (String, VoiceAskTarget) async throws -> PhoneAskResponse)?,
        streamAskResponses: (
            @Sendable (
                PhoneAskResponse,
                @escaping @Sendable (String) async -> Void
            ) async throws -> Bool
        )? = nil,
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
        let adaptedSubmitAsk: (
            @Sendable (String, VoiceAskTarget, String) async throws -> PhoneAskResponse
        )?
        if let submitAsk {
            adaptedSubmitAsk = { transcript, target, _ in
                try await submitAsk(transcript, target)
            }
        } else {
            adaptedSubmitAsk = nil
        }
        self.init(
            generator: generator,
            submit: submit,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: askTarget,
            submitAsk: adaptedSubmitAsk,
            streamAskResponses: streamAskResponses,
            operationIsAllowed: operationIsAllowed,
            permissionsAreGranted: permissionsAreGranted,
            requestPermissions: requestPermissions,
            generationTimeoutNanoseconds: generationTimeoutNanoseconds,
            followUpListenDelayNanoseconds: followUpListenDelayNanoseconds
        )
    }

    convenience init(
        generator: LocalCommandGenerating,
        submit: @escaping @Sendable (CommandEnvelope) async throws -> CommandResponse,
        capture: PushToTalkVoiceCapturing = PushToTalkVoiceCapture(),
        synthesizer: VoiceSynthesizing = SystemVoiceSynthesizer(),
        askTarget: @escaping () -> VoiceAskTarget? = { nil },
        submitAsk: @escaping @Sendable (String) async throws -> PhoneAskResponse,
        streamAskResponses: (
            @Sendable (
                PhoneAskResponse,
                @escaping @Sendable (String) async -> Void
            ) async throws -> Bool
        )? = nil,
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
        self.init(
            generator: generator,
            submit: submit,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: askTarget,
            submitAsk: { transcript, _, _ in
                try await submitAsk(transcript)
            },
            streamAskResponses: streamAskResponses,
            operationIsAllowed: operationIsAllowed,
            permissionsAreGranted: permissionsAreGranted,
            requestPermissions: requestPermissions,
            generationTimeoutNanoseconds: generationTimeoutNanoseconds,
            followUpListenDelayNanoseconds: followUpListenDelayNanoseconds
        )
    }
#endif

    deinit {
        generationTimeoutTask?.cancel()
        generationWaiter?.cancel()
        processingTask?.cancel()
        capture.abort()
        synthesizer.stop()
    }

    /// Begins a new recording. Speech output is stopped first so it cannot feed
    /// the microphone or compete with the capture audio session.
    func start(resolvedAskTarget: VoiceAskTarget? = nil) {
        guard canStart else { return }
        invalidateActiveTurn()
        resolvedAskTargetForTurn = resolvedAskTarget
        cancelProcessing()
        capture.abort()
        synthesizer.stop()

        nextSessionID &+= 1
        let sessionID = nextSessionID
        let clientTurnID = UUID().uuidString
        activeSessionID = sessionID
        activeClientTurnID = clientTurnID
        turnOutcomeOwner = TurnOutcomeOwner(
            sessionID: sessionID,
            clientTurnID: clientTurnID,
            phase: .requestingPermissions
        )
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
        invalidateActiveTurn()
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
        guard isCurrent(sessionID),
              pressActive || isFollowUpListen,
              transitionTurn(to: .capturing, sessionID: sessionID)
        else { return }
        nextCaptureAttemptID &+= 1
        let captureAttemptID = nextCaptureAttemptID
        activeCaptureAttemptID = captureAttemptID
        state = .listening
        do {
            try capture.start(
                onTranscript: { [weak self] transcript in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.isCurrentCaptureAttempt(
                                  sessionID: sessionID,
                                  captureAttemptID: captureAttemptID
                              )
                        else { return }
                        self.transcript = transcript.text
                        if transcript.isFinal {
                            self.finalTranscript = transcript.text
                        }
                    }
                },
                onStop: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.consumeCaptureAttempt(
                                  sessionID: sessionID,
                                  captureAttemptID: captureAttemptID
                              )
                        else { return }
                        self.processLatestTranscript(sessionID: sessionID)
                    }
                },
                onAbort: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.consumeCaptureAttempt(
                                  sessionID: sessionID,
                                  captureAttemptID: captureAttemptID
                              )
                        else { return }
                        self.finishAfterCaptureAbort(sessionID: sessionID)
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.consumeCaptureAttempt(
                                  sessionID: sessionID,
                                  captureAttemptID: captureAttemptID
                              )
                        else { return }
                        self.finishCaptureError(error, sessionID: sessionID)
                    }
                }
            )
        } catch {
            activeCaptureAttemptID = nil
            finishWithFailure(error, sessionID: sessionID)
        }
    }

    private func processLatestTranscript(sessionID: UInt64) {
        guard isCurrent(sessionID), state == .listening else { return }
        pressActive = false
        isFollowUpListen = false
        followUpListenIsBody = false

        // Partial text remains visible as capture feedback, but only a final
        // recognition result may initiate follow-up handling, generation, or Ask.
        let text = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pending = pendingSlot {
            handleFollowUp(text, pending: pending, sessionID: sessionID)
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
            beginAsk(for: text, sessionID: sessionID)
            return
        }
        beginGeneration(for: text, sessionID: sessionID)
    }

    private func shouldUseLocalCommand(for text: String) -> Bool {
        // Chinese / mixed speech uses Ask {agent}, not on-device classification.
        if LiveSpeechTranscriptChooser.containsCJK(text) {
            return false
        }
        return LocalVoiceUtterancePreflight.prefersLocalCommandPath(for: text)
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
        guard let clientTurnID = activeClientTurnID,
              transitionTurn(
                  to: .processing,
                  sessionID: sessionID,
                  clientTurnID: clientTurnID
              )
        else { return }
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
                self?.releaseGenerationWaiter(waiter)
                try Task.checkCancellation()
                guard self?.isCurrentTurn(
                    sessionID: sessionID,
                    clientTurnID: clientTurnID
                ) == true else { return }

                let envelope: CommandEnvelope
                do {
                    let decoded = try CommandEnvelope.decodeStrict(from: data)
                    envelope = try LocalVoiceCommandPolicy.authoritativeEnvelope(from: decoded)
                } catch {
                    self?.finishGenerationClarification(
                        error,
                        transcript: text,
                        sessionID: sessionID
                    )
                    return
                }

                try Task.checkCancellation()
                guard self?.isCurrentTurn(
                    sessionID: sessionID,
                    clientTurnID: clientTurnID
                ) == true else { return }
                let response = try await submit(envelope)
                try Task.checkCancellation()
                guard self?.isCurrentTurn(
                    sessionID: sessionID,
                    clientTurnID: clientTurnID
                ) == true else { return }
                self?.finishWithSubmission(
                    response,
                    sessionID: sessionID,
                    clientTurnID: clientTurnID
                )
            } catch is CancellationError {
                self?.releaseGenerationWaiter(waiter)
                return
            } catch {
                self?.releaseGenerationWaiter(waiter)
                guard self?.isCurrentTurn(
                    sessionID: sessionID,
                    clientTurnID: clientTurnID
                ) == true else { return }
                if LocalVoiceCommandErrorPolicy.requiresClarification(error) {
                    self?.finishGenerationClarification(
                        error,
                        transcript: text,
                        sessionID: sessionID
                    )
                } else {
                    self?.finishWithFailure(error, sessionID: sessionID)
                }
            }
        }
    }

    private func beginAsk(for text: String, sessionID: UInt64) {
        guard let submitAsk,
              let target = resolvedAskTargetForTurn ?? askTarget()
        else {
            finishWithClarification(
                sessionID: sessionID,
                kind: .selectAgent,
                speak: "Select an agent first."
            )
            return
        }
        guard let clientTurnID = activeClientTurnID,
              transitionTurn(
                  to: .requestInFlight,
                  sessionID: sessionID,
                  clientTurnID: clientTurnID
              )
        else { return }
        state = .asking(target.label)
        processingTask = Task { @MainActor [weak self] in
            do {
                let outcome: PhoneAskSubmissionOutcome
                do {
                    let initialOutcome = try await submitAsk(text, target, clientTurnID)
                    try Self.validateAskSubmissionOutcome(
                        initialOutcome,
                        expectedAgentID: target.agentID
                    )
                    outcome = initialOutcome
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        throw CancellationError()
                    }
                    guard let self,
                          self.isCurrentTurn(
                              sessionID: sessionID,
                              clientTurnID: clientTurnID
                          )
                    else { return }
                    guard Self.isAskDeliveryUnknown(error) else { throw error }
                    guard self.transitionTurn(
                        to: .deliveryUnknown,
                        sessionID: sessionID,
                        clientTurnID: clientTurnID
                    ), self.transitionTurn(
                        to: .reconciling,
                        sessionID: sessionID,
                        clientTurnID: clientTurnID
                    ) else { return }
                    let reconciledOutcome = try await submitAsk(text, target, clientTurnID)
                    try Self.validateAskSubmissionOutcome(
                        reconciledOutcome,
                        expectedAgentID: target.agentID
                    )
                    outcome = reconciledOutcome
                }

                guard let self,
                      self.isCurrentTurn(
                          sessionID: sessionID,
                          clientTurnID: clientTurnID
                      ),
                      self.transitionTurn(
                          to: .accepted,
                          sessionID: sessionID,
                          clientTurnID: clientTurnID
                      )
                else { return }
                if outcome == .alreadyReconciled {
                    self.finishWithReconciledAsk(
                        label: target.label,
                        sessionID: sessionID,
                        clientTurnID: clientTurnID
                    )
                    return
                }
                let response: PhoneAskResponse
                switch outcome {
                case let .accepted(value), let .alreadyAccepted(value):
                    response = value
                case .alreadyReconciled:
                    return
                }
                // A successful POST must leave Asking. Do not checkCancellation
                // here: a cancel after the network call would swallow the
                // response and leave the dock stuck on Asking.
                var spokeAgentResponse = false
                if let streamAskResponses = self.streamAskResponses {
                    do {
                        spokeAgentResponse = try await streamAskResponses(response) {
                            [weak self] responseText in
                            await MainActor.run {
                                self?.speakAskResponse(
                                    responseText,
                                    sessionID: sessionID,
                                    clientTurnID: clientTurnID
                                )
                            }
                        }
                    } catch {
                        // The POST was accepted. A stream/poll failure cannot
                        // downgrade delivery to capture or submission failure.
                        guard self.isCurrentTurn(
                            sessionID: sessionID,
                            clientTurnID: clientTurnID
                        ) else { return }
                        spokeAgentResponse = false
                    }
                }
                guard self.isCurrentTurn(
                    sessionID: sessionID,
                    clientTurnID: clientTurnID
                ) else { return }
                self.finishWithAsk(
                    response,
                    label: target.label,
                    spokeAgentResponse: spokeAgentResponse,
                    sessionID: sessionID,
                    clientTurnID: clientTurnID
                )
            } catch is CancellationError {
                return
            } catch {
                guard self?.isCurrentTurn(
                    sessionID: sessionID,
                    clientTurnID: clientTurnID
                ) == true else { return }
                if Self.isAskDeliveryUnknown(error) {
                    self?.finishDeliveryUnknown(
                        sessionID: sessionID,
                        clientTurnID: clientTurnID
                    )
                    return
                }
                if Self.isAskListenerChanged(error) {
                    self?.finishWithClarification(
                        sessionID: sessionID,
                        kind: .selectAgent,
                        speak: "The listener changed. Select the agent again."
                    )
                    return
                }
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

    private static func isAskListenerChanged(_ error: Error) -> Bool {
        if (error as? VoiceAskSubmissionError) == .listenerChanged {
            return true
        }
        guard let apiError = error as? APIClientError,
              case let .badStatus(status, _, metadata) = apiError,
              status == 409
        else { return false }
        return metadata.errorCode == "ask_listener_fence_mismatch"
            || metadata.errorCode == "legacy_ask_fence_unavailable"
    }

    private static func validateAskSubmissionOutcome(
        _ outcome: PhoneAskSubmissionOutcome,
        expectedAgentID: String
    ) throws {
        switch outcome {
        case let .accepted(response), let .alreadyAccepted(response):
            try response.validate(expectedAgentID: expectedAgentID)
        case .alreadyReconciled:
            return
        }
    }

    private static func isAskDeliveryUnknown(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is PhoneAskResponseValidationError { return true }
        if let apiError = error as? APIClientError {
            switch apiError {
            case let .badStatus(status, _, metadata):
                return metadata.retryable
                    || status == 408
                    || status == 425
                    || status == 429
                    || status >= 500
            case .decoding:
                return true
            case let .network(message):
                return message.lowercased() != "cancelled"
            case .noToken,
                 .missingPushToken,
                 .invalidPushToken,
                 .invalidBaseURL:
                return false
            }
        }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code != URLError.cancelled.rawValue
    }

    private func finishGenerationClarification(
        _ error: Error? = nil,
        transcript: String? = nil,
        sessionID: UInt64
    ) {
        if pendingSlot != nil {
            finishFollowUpUnresolved(sessionID: sessionID)
            return
        }
        if case .clarificationRequired(.unsupportedIntent) =
            error as? LocalCommandEnvelopeCanonicalizerError,
           submitAsk != nil,
           let transcript,
           !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            beginAsk(for: transcript, sessionID: sessionID)
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
        guard claimTerminalOutcome(.clarification, sessionID: sessionID) else { return }
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
            guard let clientTurnID = activeClientTurnID,
                  transitionTurn(
                      to: .awaitingClarification,
                      sessionID: sessionID,
                      clientTurnID: clientTurnID
                  )
            else { return }
            nextClarificationSpeechID &+= 1
            let speechID = nextClarificationSpeechID
            activeClarificationSpeechID = speechID
            synthesizer.speak(prompt) { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.handleClarificationSpeechFinished(
                        result,
                        sessionID: sessionID,
                        clientTurnID: clientTurnID,
                        speechID: speechID
                    )
                }
            }
            return
        }
        guard claimTerminalOutcome(.clarification, sessionID: sessionID) else { return }
        let shouldSpeak = claimTerminalSpeech(sessionID: sessionID)
        activeSessionID = nil
        if shouldSpeak {
            synthesizer.speak(prompt)
        }
    }

    private func handleClarificationSpeechFinished(
        _ result: VoiceSynthesisResult,
        sessionID: UInt64,
        clientTurnID: String,
        speechID: UInt64
    ) {
        guard isCurrentTurn(sessionID: sessionID, clientTurnID: clientTurnID),
              activeClarificationSpeechID == speechID,
              result == .finished,
              pendingSlot != nil,
              !didAutoListenForPendingSlot,
              isPendingSlotClarification
        else { return }

        activeClarificationSpeechID = nil
        didAutoListenForPendingSlot = true
        followUpStartRetries = 0
        isFollowUpListen = true
        followUpListenIsBody = pendingSlotIsBody
        transcript = ""
        finalTranscript = ""
        synthesizer.stop()
        startFollowUpCapture(
            sessionID: sessionID,
            clientTurnID: clientTurnID
        )
    }

    private func startFollowUpCapture(
        sessionID: UInt64,
        clientTurnID: String
    ) {
        let delay = followUpListenDelayNanoseconds
        guard delay > 0 else {
            startCapture(sessionID: sessionID)
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self,
                  self.isCurrentTurn(
                      sessionID: sessionID,
                      clientTurnID: clientTurnID
                  ),
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
        guard let clientTurnID = activeClientTurnID,
              isCurrentTurn(sessionID: sessionID, clientTurnID: clientTurnID),
              pendingSlot != nil,
              followUpStartRetries < 1
        else { return false }

        followUpStartRetries += 1
        isFollowUpListen = true
        followUpListenIsBody = pendingSlotIsBody
        transcript = ""
        finalTranscript = ""
        state = .clarificationRequired(pendingClarificationKind)
        startFollowUpCapture(
            sessionID: sessionID,
            clientTurnID: clientTurnID
        )
        return true
    }

    private func finishWithSubmission(
        _ response: CommandResponse,
        sessionID: UInt64,
        clientTurnID: String
    ) {
        guard claimTerminalOutcome(
            .submitted,
            sessionID: sessionID,
            clientTurnID: clientTurnID
        ) else { return }
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
        spokeAgentResponse: Bool = false,
        sessionID: UInt64,
        clientTurnID: String
    ) {
        guard claimTerminalOutcome(
            .asked,
            sessionID: sessionID,
            clientTurnID: clientTurnID
        ) else { return }
        let shouldSpeak = !spokeAgentResponse && claimAcknowledgementSpeech(
            sessionID: sessionID,
            clientTurnID: clientTurnID
        )
        activeSessionID = nil
        clearPendingSlot()
        clearGenerationTimeout()
        processingTask = nil
        generationWaiter = nil
        let spokenLabel = (response.agent_label?.isEmpty == false)
            ? (response.agent_label ?? label)
            : label
        state = .asked(spokenLabel)
        if shouldSpeak {
            synthesizer.speak("Sent to \(spokenLabel).")
        }
    }

    private func finishWithReconciledAsk(
        label: String,
        sessionID: UInt64,
        clientTurnID: String
    ) {
        guard claimTerminalOutcome(
            .asked,
            sessionID: sessionID,
            clientTurnID: clientTurnID
        ) else { return }
        activeSessionID = nil
        clearPendingSlot()
        clearGenerationTimeout()
        processingTask = nil
        generationWaiter = nil
        state = .asked(label)
    }

    private func speakAskResponse(
        _ responseText: String,
        sessionID: UInt64,
        clientTurnID: String
    ) {
        guard isCurrentTurn(sessionID: sessionID, clientTurnID: clientTurnID) else { return }
        let text = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              claimTerminalSpeech(
                  sessionID: sessionID,
                  clientTurnID: clientTurnID
              )
        else { return }
        synthesizer.speak(text)
    }

    private func finishDeliveryUnknown(
        sessionID: UInt64,
        clientTurnID: String
    ) {
        let error = LocalVoiceCommandControllerError.deliveryUnconfirmed
        finishWithFailure(
            error,
            sessionID: sessionID,
            clientTurnID: clientTurnID,
            speak: error.localizedDescription
        )
    }

    private func finishWithFailure(
        _ error: Error,
        sessionID: UInt64,
        clientTurnID: String? = nil,
        speak prompt: String? = nil
    ) {
        guard claimTerminalOutcome(
            .failed,
            sessionID: sessionID,
            clientTurnID: clientTurnID
        ) else { return }
        let shouldSpeak = prompt != nil && claimTerminalSpeech(
            sessionID: sessionID,
            clientTurnID: clientTurnID
        )
        activeSessionID = nil
        pressActive = false
        isFollowUpListen = false
        clearPendingSlot()
        cancelProcessing()
        capture.abort()
        synthesizer.stop()
        state = .failed(error.localizedDescription)
        if shouldSpeak, let prompt {
            synthesizer.speak(prompt)
        }
    }

    private func finishAfterCaptureAbort(sessionID: UInt64) {
        guard claimTerminalOutcome(.aborted, sessionID: sessionID) else { return }
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

    private func releaseGenerationWaiter(_ waiter: VoiceGenerationWaiter) {
        guard generationWaiter === waiter else { return }
        clearGenerationTimeout()
        generationWaiter = nil
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
        activeClarificationSpeechID = nil
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

    private func invalidateActiveTurn() {
        activeSessionID = nil
        activeClientTurnID = nil
        turnOutcomeOwner = nil
        activeCaptureAttemptID = nil
        activeClarificationSpeechID = nil
    }

    private func transitionTurn(
        to phase: TurnPhase,
        sessionID: UInt64,
        clientTurnID: String? = nil
    ) -> Bool {
        guard isCurrent(sessionID),
              var owner = turnOutcomeOwner,
              clientTurnID == nil || owner.clientTurnID == clientTurnID
        else { return false }
        owner.phase = phase
        turnOutcomeOwner = owner
        return true
    }

    private func claimTerminalOutcome(
        _ outcome: TerminalOutcome,
        sessionID: UInt64,
        clientTurnID: String? = nil
    ) -> Bool {
        guard activeSessionID == sessionID,
              operationIsAllowed(),
              var owner = turnOutcomeOwner,
              owner.sessionID == sessionID,
              owner.clientTurnID == activeClientTurnID,
              clientTurnID == nil || owner.clientTurnID == clientTurnID,
              owner.terminalOutcome == nil
        else { return false }
        owner.phase = .terminal
        owner.terminalOutcome = outcome
        turnOutcomeOwner = owner
        activeCaptureAttemptID = nil
        activeClarificationSpeechID = nil
        return true
    }

    private func claimTerminalSpeech(
        sessionID: UInt64,
        clientTurnID: String? = nil
    ) -> Bool {
        guard activeSessionID == sessionID,
              operationIsAllowed(),
              var owner = turnOutcomeOwner,
              owner.sessionID == sessionID,
              owner.clientTurnID == activeClientTurnID,
              clientTurnID == nil || owner.clientTurnID == clientTurnID,
              !owner.terminalSpeechClaimed
        else { return false }
        owner.terminalSpeechClaimed = true
        turnOutcomeOwner = owner
        return true
    }

    /// The sent/waiting acknowledgement is not an answer delivery claim.
    /// App-level reconciliation may therefore announce the canonical backend
    /// answer later, including after this controller has released the dock.
    private func claimAcknowledgementSpeech(
        sessionID: UInt64,
        clientTurnID: String
    ) -> Bool {
        guard activeSessionID == sessionID,
              operationIsAllowed(),
              var owner = turnOutcomeOwner,
              owner.sessionID == sessionID,
              owner.clientTurnID == activeClientTurnID,
              owner.clientTurnID == clientTurnID,
              !owner.acknowledgementSpeechClaimed
        else { return false }
        owner.acknowledgementSpeechClaimed = true
        turnOutcomeOwner = owner
        return true
    }

    private func isCurrentTurn(
        sessionID: UInt64,
        clientTurnID: String
    ) -> Bool {
        isCurrent(sessionID)
            && turnOutcomeOwner?.clientTurnID == clientTurnID
    }

    private func isCurrentCaptureAttempt(
        sessionID: UInt64,
        captureAttemptID: UInt64
    ) -> Bool {
        isCurrent(sessionID)
            && activeCaptureAttemptID == captureAttemptID
            && state == .listening
    }

    private func consumeCaptureAttempt(
        sessionID: UInt64,
        captureAttemptID: UInt64
    ) -> Bool {
        guard isCurrentCaptureAttempt(
            sessionID: sessionID,
            captureAttemptID: captureAttemptID
        ) else { return false }
        activeCaptureAttemptID = nil
        return true
    }

    private func isCurrent(_ sessionID: UInt64) -> Bool {
        activeSessionID == sessionID
            && operationIsAllowed()
            && turnOutcomeOwner?.sessionID == sessionID
            && turnOutcomeOwner?.clientTurnID == activeClientTurnID
            && turnOutcomeOwner?.terminalOutcome == nil
    }

    private var canStart: Bool {
        guard operationIsAllowed() else { return false }
        switch state {
        case .idle, .clarificationRequired, .submitted, .asked, .failed:
            return true
        case .requestingPermissions, .listening, .processing, .asking:
            return false
        }
    }
}

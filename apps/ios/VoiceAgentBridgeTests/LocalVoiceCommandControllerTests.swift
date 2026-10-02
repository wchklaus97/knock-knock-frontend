import Foundation
import XCTest
@testable import VoiceAgentBridge

private final class ControlledVoiceCapture: PushToTalkVoiceCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var abortCount = 0

    private var onTranscript: ((PushToTalkVoiceCapture.Transcript) -> Void)?
    private var onStop: ((PushToTalkVoiceCapture.StopReason) -> Void)?
    private var onAbort: ((PushToTalkVoiceCapture.AbortReason) -> Void)?
    private var onError: ((PushToTalkVoiceCapture.CaptureError) -> Void)?

    func start(
        onTranscript: @escaping (PushToTalkVoiceCapture.Transcript) -> Void,
        onStop: @escaping (PushToTalkVoiceCapture.StopReason) -> Void,
        onAbort: @escaping (PushToTalkVoiceCapture.AbortReason) -> Void,
        onError: @escaping (PushToTalkVoiceCapture.CaptureError) -> Void
    ) throws {
        startCount += 1
        self.onTranscript = onTranscript
        self.onStop = onStop
        self.onAbort = onAbort
        self.onError = onError
    }

    func stop() {
        stopCount += 1
    }

    func abort() {
        abortCount += 1
    }

    func emitTranscript(_ text: String, isFinal: Bool) {
        onTranscript?(.init(text: text, isFinal: isFinal))
    }

    func emitTranscriptFromBackground(_ text: String, isFinal: Bool) {
        let callback = onTranscript
        DispatchQueue.global(qos: .userInitiated).async {
            callback?(.init(text: text, isFinal: isFinal))
        }
    }

    func emitConcurrentFinalStopsFromBackground() {
        let callback = onStop
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                callback?(.finalTranscript)
            }
        }
    }

    func emitStop(_ reason: PushToTalkVoiceCapture.StopReason) {
        onStop?(reason)
    }

    func emitAbort(_ reason: PushToTalkVoiceCapture.AbortReason) {
        onAbort?(reason)
    }

    func emitError(_ error: PushToTalkVoiceCapture.CaptureError) {
        onError?(error)
    }
}

private final class ControlledCommandGenerator: LocalCommandGenerating {
    private let lock = NSLock()
    private var storedTranscripts: [String] = []
    private(set) var cancelCount = 0
    var onGenerate: (() -> Void)?
    /// Completes inside `generateCommand` so tests do not race `completeNext`.
    var cannedResult: Result<Data, Error>?
    private var completions: [(Result<Data, Error>) -> Void] = []
    private var pendingGenerationExpectations: [XCTestExpectation] = []

    var transcripts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedTranscripts
    }

    func generateCommand(for transcript: String, completion: @escaping (Result<Data, Error>) -> Void) {
        let immediate: Result<Data, Error>?
        var expectations: [XCTestExpectation] = []
        lock.lock()
        storedTranscripts.append(transcript)
        immediate = cannedResult
        if immediate == nil {
            completions.append(completion)
            expectations = pendingGenerationExpectations
            pendingGenerationExpectations.removeAll()
        }
        lock.unlock()
        expectations.forEach { $0.fulfill() }
        if let immediate {
            completion(immediate)
            return
        }
        onGenerate?()
    }

    func expectPendingGeneration(_ description: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        lock.lock()
        if completions.isEmpty {
            pendingGenerationExpectations.append(expectation)
            lock.unlock()
        } else {
            lock.unlock()
            expectation.fulfill()
        }
        return expectation
    }

    func completeNext(with result: Result<Data, Error>) {
        lock.lock()
        guard !completions.isEmpty else {
            lock.unlock()
            XCTFail("No pending generation")
            return
        }
        let pending = completions.removeFirst()
        lock.unlock()
        pending(result)
    }

    func cancelGeneration() {
        lock.lock()
        let hasPending = !completions.isEmpty
        lock.unlock()
        guard hasPending else { return }
        cancelCount += 1
    }
}

private final class RecordingVoiceSynthesizer: VoiceSynthesizing {
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0
    var completeImmediately = true
    private var pendingCompletion: ((VoiceSynthesisResult) -> Void)?

    func speak(
        _ text: String,
        completion: @escaping (VoiceSynthesisResult) -> Void
    ) {
        spoken.append(text)
        if completeImmediately {
            completion(.finished)
        } else {
            pendingCompletion = completion
        }
    }

    func finishSpeaking(_ result: VoiceSynthesisResult = .finished) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(result)
    }

    func stop() {
        stopCount += 1
        finishSpeaking(.cancelled)
    }
}

private final class VoiceTestBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class SubmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandResponse, Error>?
    private let onStart: () -> Void
    private let onCancel: () -> Void

    init(onStart: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onStart = onStart
        self.onCancel = onCancel
    }

    func wait() async throws -> CommandResponse {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                onStart()
            }
        }, onCancel: {
            onCancel()
        })
    }

    func succeed(with response: CommandResponse) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: response)
    }
}

@MainActor
final class LocalVoiceCommandControllerTests: XCTestCase {
    func testGracefulReleaseWaitsForDelayedFinalTranscriptBeforeSubmitting() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let submitted = expectation(description: "submitted")
        let submittedTranscript = VoiceTestBox<String?>(nil)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer
        ) { envelope in
            submittedTranscript.value = envelope.args["q"]?.stringValue
            submitted.fulfill()
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("partial", isFinal: false)
        controller.stop()

        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(generator.transcripts.isEmpty)

        capture.emitTranscript("final transcript", isFinal: true)
        capture.emitStop(.userReleased)
        await drainTasks()

        XCTAssertEqual(generator.transcripts, ["final transcript"])
        generator.completeNext(with: .success(Self.envelopeData(query: "final transcript")))
        await fulfillment(of: [submitted], timeout: 1)
        await drainTasks()

        XCTAssertEqual(submittedTranscript.value, "final transcript")
        XCTAssertEqual(controller.state, .submitted("cmd_voice_1"))
    }

    func testAcknowledgeSettledCommandReturnsSubmittedDockToIdleWithoutAbortingListen() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let submitted = expectation(description: "submitted for settle")
        let controller = makeController(
            generator: generator,
            capture: capture
        ) { _ in
            submitted.fulfill()
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("search history", isFinal: true)
        capture.emitStop(.userReleased)
        await waitUntil(timeout: 1) { !generator.transcripts.isEmpty }
        generator.completeNext(with: .success(Self.envelopeData(query: "history")))
        await fulfillment(of: [submitted], timeout: 1)
        await waitUntil(timeout: 1) {
            if case .submitted = controller.state { return true }
            return false
        }

        XCTAssertEqual(controller.state, .submitted("cmd_voice_1"))
        controller.acknowledgeSettledCommand()
        XCTAssertEqual(controller.state, .idle)

        controller.start()
        XCTAssertEqual(controller.state, .listening)
        let abortCountWhileListening = capture.abortCount
        controller.acknowledgeSettledCommand()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.abortCount, abortCountWhileListening)
    }

    func testCancelAfterReleaseSuppressesDelayedFinalTranscriptAndStopCallback() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let submitted = VoiceTestBox(false)
        let controller = makeController(generator: generator, capture: capture) { _ in
            submitted.value = true
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("partial", isFinal: false)
        controller.stop()
        controller.cancel()

        capture.emitTranscript("late final", isFinal: true)
        capture.emitStop(.userReleased)
        await drainTasks()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.transcript, "")
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertFalse(submitted.value)
    }

    func testCancelDuringPermissionRequestPreventsCaptureAndSubmission() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let submitted = VoiceTestBox(false)
        var permissionCompletion: ((Result<Void, PushToTalkVoiceCapture.CaptureError>) -> Void)?
        let controller = LocalVoiceCommandController(
            generator: generator,
            submit: { _ in
                submitted.value = true
                return try Self.response()
            },
            capture: capture,
            synthesizer: RecordingVoiceSynthesizer(),
            permissionsAreGranted: { false },
            requestPermissions: { permissionCompletion = $0 }
        )

        controller.start()
        XCTAssertEqual(controller.state, .requestingPermissions)
        controller.cancel()
        permissionCompletion?(.success(()))
        await drainTasks()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertFalse(submitted.value)
    }

    func testCancelDuringInferenceDropsLateModelCompletionWithoutSubmitting() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let submitted = VoiceTestBox(false)
        let controller = makeController(generator: generator, capture: capture) { _ in
            submitted.value = true
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("search history", isFinal: true)
        capture.emitStop(.finalTranscript)
        await drainTasks()
        XCTAssertEqual(generator.transcripts, ["search history"])
        XCTAssertEqual(controller.state, .processing)

        controller.cancel()
        XCTAssertEqual(generator.cancelCount, 1)
        generator.completeNext(with: .success(Self.envelopeData(query: "search history")))
        await drainTasks()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(submitted.value)
    }

    func testInvalidatedScopeCannotRestartRetainedControllerOrSubmitLateInference() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let submitted = VoiceTestBox(false)
        var operationIsAllowed = true
        let controller = LocalVoiceCommandController(
            generator: generator,
            submit: { _ in
                submitted.value = true
                return try Self.response()
            },
            capture: capture,
            synthesizer: RecordingVoiceSynthesizer(),
            operationIsAllowed: { operationIsAllowed },
            permissionsAreGranted: { true },
            requestPermissions: { _ in
                XCTFail("Permissions should not be requested in this test")
            }
        )

        controller.start()
        capture.emitTranscript("search old account history", isFinal: true)
        capture.emitStop(.finalTranscript)
        await drainTasks()
        XCTAssertEqual(generator.transcripts, ["search old account history"])

        operationIsAllowed = false
        controller.abort()
        controller.start()
        generator.completeNext(with: .success(Self.envelopeData(query: "old account history")))
        await drainTasks()

        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(submitted.value)
    }

    func testCancelBetweenWaiterCommitAndGeneratorStartLeavesNoActiveGeneration() async {
        let startCommitted = expectation(description: "waiter committed generation start")
        let operationStarted = expectation(description: "generation operation started")
        operationStarted.assertForOverFulfill = true
        let cancellationInvoked = expectation(description: "generation cancellation invoked")
        cancellationInvoked.assertForOverFulfill = true
        let allowOperationToStart = DispatchSemaphore(value: 0)
        let waiter = VoiceGenerationWaiter {
            startCommitted.fulfill()
            _ = allowOperationToStart.wait(timeout: .now() + 2)
        }

        let task = Task.detached {
            try await waiter.value { _ in
                operationStarted.fulfill()
            } onCancel: {
                cancellationInvoked.fulfill()
            }
        }

        await fulfillment(of: [startCommitted], timeout: 1)
        waiter.cancel()
        allowOperationToStart.signal()
        await fulfillment(of: [operationStarted, cancellationInvoked], timeout: 1)

        do {
            _ = try await task.value
            XCTFail("A cancelled waiter must not return generation output")
        } catch is CancellationError {
            // Expected. The operation that raced with cancellation was cancelled.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancelDuringAPICancelsTaskAndIgnoresLateResponse() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let generationStarted = expectation(description: "generation started")
        generator.onGenerate = { generationStarted.fulfill() }
        let apiStarted = expectation(description: "API started")
        let apiCancelled = expectation(description: "API cancelled")
        let gate = SubmissionGate(
            onStart: { apiStarted.fulfill() },
            onCancel: { apiCancelled.fulfill() }
        )
        let controller = makeController(generator: generator, capture: capture) { _ in
            try await gate.wait()
        }

        controller.start()
        capture.emitTranscript("search history", isFinal: true)
        capture.emitStop(.finalTranscript)
        await fulfillment(of: [generationStarted], timeout: 1)
        generator.completeNext(with: .success(Self.envelopeData(query: "search history")))
        await fulfillment(of: [apiStarted], timeout: 1)

        controller.cancel()
        await fulfillment(of: [apiCancelled], timeout: 1)
        gate.succeed(with: try Self.response())
        await drainTasks()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.transcript, "")
    }

    func testAudioAbortSuppressesStaleStopCallbackAndDoesNotAutoResume() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let submitted = VoiceTestBox(false)
        let controller = makeController(generator: generator, capture: capture) { _ in
            submitted.value = true
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("search history", isFinal: false)
        capture.emitAbort(.audioInterrupted)
        capture.emitStop(.silence)
        await drainTasks()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.transcript, "")
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertFalse(submitted.value)
        XCTAssertEqual(capture.startCount, 1)
    }

    func testNoSpeechStopClarifiesWithoutGenerationOrSubmission() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let submitted = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer
        ) { _ in
            submitted.value = true
            return try Self.response()
        }

        controller.start()
        capture.emitStop(.noSpeech)
        await drainTasks()

        XCTAssertEqual(controller.state, .clarificationRequired(.generic))
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertFalse(submitted.value)
        XCTAssertEqual(synthesizer.spoken, ["I didn't catch that."])
    }

    func testStartStopsTTSBeforeCapture() {
        let capture = ControlledVoiceCapture()
        let synthesizer = RecordingVoiceSynthesizer()
        let controller = makeController(
            generator: ControlledCommandGenerator(),
            capture: capture,
            synthesizer: synthesizer
        ) { _ in
            XCTFail("Nothing should be submitted while capture is still active")
            return try Self.response()
        }

        controller.start()

        XCTAssertEqual(synthesizer.stopCount, 1)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(controller.state, .listening)
    }

    func testStartWhileAskingDoesNotStartSecondCapture() async {
        let capture = ControlledVoiceCapture()
        let askStarted = expectation(description: "ask started")
        let askGate = VoiceTestBox<CheckedContinuation<Void, Never>?>(nil)
        let controller = makeController(
            generator: ControlledCommandGenerator(),
            capture: capture,
            askTarget: { VoiceAskTarget(agentID: "agt_live", label: "live-agent") },
            submitAsk: { _, _ in
                askStarted.fulfill()
                await withCheckedContinuation { continuation in
                    askGate.value = continuation
                }
                return PhoneAskResponse(
                    ask_id: "ask_reentry",
                    agent_id: "agt_live",
                    agent_label: "live-agent",
                    session_id: "ses_reentry",
                    turn_sequence: 1,
                    status: "queued"
                )
            }
        ) { _ in
            XCTFail("Ask must not submit a local command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Help with APNs", isFinal: true)
        capture.emitStop(.finalTranscript)
        await fulfillment(of: [askStarted], timeout: 1)

        XCTAssertEqual(controller.state, .asking("live-agent"))
        controller.start()
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(controller.state, .asking("live-agent"))

        await waitUntil(timeout: 1) {
            askGate.value != nil
        }
        let continuation = askGate.value
        askGate.value = nil
        continuation?.resume()
        await waitUntil(timeout: 1) {
            controller.state == .asked("live-agent")
        }
    }

    func testVoiceAskAgentResolverRequiresUnambiguousListeningTarget() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        func agent(_ id: String, expiresIn seconds: TimeInterval) -> Agent {
            Agent(
                agent_id: id,
                user_id: "usr_test",
                label: id,
                host_label: nil,
                created_at: formatter.string(from: now.addingTimeInterval(-3_600)),
                last_seen_at: formatter.string(from: now.addingTimeInterval(-10)),
                listener_binding_id: "binding_\(id)",
                listener_lease_id: "lease_\(id)",
                listener_generation: 1,
                listener_chat_id: "chat_\(id)",
                listener_expires_at: formatter.string(from: now.addingTimeInterval(seconds))
            )
        }

        let stale = agent("agt_stale", expiresIn: -1)
        let liveOne = agent("agt_one", expiresIn: 60)
        let liveTwo = agent("agt_two", expiresIn: 120)

        XCTAssertNil(VoiceAskAgentResolver.resolve(
            selectedId: stale.agent_id,
            agents: [stale],
            now: now
        ))
        XCTAssertEqual(
            VoiceAskAgentResolver.resolve(
                selectedId: stale.agent_id,
                agents: [stale, liveOne],
                now: now
            )?.agent_id,
            liveOne.agent_id
        )
        XCTAssertNil(VoiceAskAgentResolver.resolve(
            selectedId: stale.agent_id,
            agents: [stale, liveOne, liveTwo],
            now: now
        ))
        XCTAssertEqual(
            VoiceAskAgentResolver.resolve(
                selectedId: liveTwo.agent_id,
                agents: [liveOne, liveTwo],
                now: now
            )?.agent_id,
            liveTwo.agent_id
        )
    }

    func testControllerReappliesLocalRiskPolicyBeforeSubmission() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let submitted = expectation(description: "submitted with authoritative policy")
        let received = VoiceTestBox<CommandEnvelope?>(nil)
        let controller = makeController(generator: generator, capture: capture) { envelope in
            received.value = envelope
            submitted.fulfill()
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("send it", isFinal: true)
        capture.emitStop(.finalTranscript)
        await drainTasks()
        generator.completeNext(with: .success(Data(#"""
        {
          "schema_version":1,
          "command_id":"cmd_voice_unsafe",
          "intent":"send_message",
          "args":{"recipient":"John","body":"Hello"},
          "risk_level":"low",
          "needs_confirmation":false,
          "idempotency_key":"idem_voice_unsafe",
          "confidence":0.99,
          "locale":"en-HK",
          "timezone":"Asia/Hong_Kong"
        }
        """#.utf8)))

        await fulfillment(of: [submitted], timeout: 1)
        XCTAssertEqual(received.value?.riskLevel, .high)
        XCTAssertEqual(received.value?.needsConfirmation, true)
    }

    func testControllerClarifiesUnsupportedHighConfidenceIntent() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let submitted = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer
        ) { _ in
            submitted.value = true
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("transfer money", isFinal: true)
        capture.emitStop(.finalTranscript)
        await drainTasks()
        generator.completeNext(with: .success(Data(#"""
        {
          "schema_version":1,
          "command_id":"cmd_voice_bad",
          "intent":"transfer_money",
          "args":{"recipient":"John","amount":100},
          "risk_level":"low",
          "needs_confirmation":false,
          "idempotency_key":"idem_voice_bad",
          "confidence":1.0,
          "locale":"en-HK",
          "timezone":"Asia/Hong_Kong"
        }
        """#.utf8)))
        await drainTasks()

        XCTAssertFalse(submitted.value)
        XCTAssertEqual(controller.state, .clarificationRequired(.generic))
        XCTAssertEqual(synthesizer.spoken, ["I didn't catch that."])
    }

    func testGeneratorClarificationFailureUsesProductionControllerPath() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let submitted = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer
        ) { _ in
            submitted.value = true
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("remind me sometime", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            generator.transcripts == ["remind me sometime"]
        }
        generator.completeNext(with: .failure(
            LocalCommandEnvelopeCanonicalizerError.clarificationRequired(.lowConfidence)
        ))
        await waitUntil(timeout: 1) {
            controller.state == .clarificationRequired(.generic)
        }

        XCTAssertFalse(submitted.value)
        XCTAssertEqual(controller.state, .clarificationRequired(.generic))
        XCTAssertEqual(synthesizer.spoken, ["I didn't catch that."])
    }

    func testStopWithPartialOnlyClarifiesAndDoesNotGenerate() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let submitted = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer
        ) { _ in
            submitted.value = true
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("partial command", isFinal: false)
        capture.emitStop(.userReleased)
        await drainTasks()

        XCTAssertEqual(controller.state, .clarificationRequired(.generic))
        XCTAssertEqual(controller.transcript, "partial command")
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertFalse(submitted.value)
        XCTAssertEqual(synthesizer.spoken, ["I didn't catch that."])
    }

    func testPartialOnlyTranscriptNeverPostsRemoteAsk() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let askSubmitted = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: {
                VoiceAskTarget(agentID: "agt_codex", label: "Codex")
            },
            submitAsk: { _, target in
                askSubmitted.value = true
                return PhoneAskResponse(
                    ask_id: "ask_partial",
                    agent_id: target.agentID,
                    agent_label: target.label,
                    session_id: nil,
                    status: "queued"
                )
            }
        ) { _ in
            XCTFail("Partial-only speech must not submit a local command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("partial remote request", isFinal: false)
        capture.emitStop(.userReleased)
        await waitUntil(timeout: 1) {
            controller.state == .clarificationRequired(.generic)
        }
        await drainTasks()

        XCTAssertEqual(controller.transcript, "partial remote request")
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertFalse(askSubmitted.value)
        XCTAssertEqual(synthesizer.spoken, ["I didn't catch that."])
    }

    func testGenerationTimeoutFailsWithoutSubmittingLateSuccess() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let submitted = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            generationTimeoutNanoseconds: 50_000_000
        ) { _ in
            submitted.value = true
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("search history", isFinal: true)
        capture.emitStop(.finalTranscript)
        await drainTasks()
        XCTAssertEqual(generator.transcripts, ["search history"])
        XCTAssertEqual(controller.state, .processing)

        await waitUntil(timeout: 1) {
            if case .failed = controller.state { return true }
            return false
        }

        XCTAssertEqual(
            controller.state,
            .failed(LocalVoiceCommandControllerError.generationTimedOut.localizedDescription)
        )
        XCTAssertEqual(generator.cancelCount, 1)
        XCTAssertFalse(submitted.value)

        generator.completeNext(with: .success(Self.envelopeData(query: "search history")))
        await drainTasks()

        XCTAssertFalse(submitted.value)
        XCTAssertEqual(
            controller.state,
            .failed(LocalVoiceCommandControllerError.generationTimedOut.localizedDescription)
        )
    }

    func testCancelDuringGenerationTimeoutKeepsIdleAndIgnoresTimeoutFailure() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let submitted = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            generationTimeoutNanoseconds: 80_000_000
        ) { _ in
            submitted.value = true
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("search history", isFinal: true)
        capture.emitStop(.finalTranscript)
        await drainTasks()
        XCTAssertEqual(controller.state, .processing)

        controller.cancel()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.transcript, "")

        try? await Task.sleep(nanoseconds: 200_000_000)
        await drainTasks()
        generator.completeNext(with: .success(Self.envelopeData(query: "search history")))
        await drainTasks()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(submitted.value)
    }

    func testMissingRecipientAsksThenFillsFromFollowUpListen() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        synthesizer.completeImmediately = false
        let submitted = expectation(description: "submitted filled send")
        let received = VoiceTestBox<CommandEnvelope?>(nil)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer
        ) { envelope in
            received.value = envelope
            submitted.fulfill()
            return try Self.response()
        }

        let firstGeneration = generator.expectPendingGeneration(
            "first send generation registered"
        )
        controller.start()
        capture.emitTranscript("Send him a message saying yes", isFinal: true)
        capture.emitStop(.finalTranscript)
        await fulfillment(of: [firstGeneration], timeout: 1)
        generator.completeNext(with: .failure(
            LocalCommandEnvelopeCanonicalizerError.clarificationRequired(
                .missingSendRecipient(body: "yes")
            )
        ))
        await waitUntil(timeout: 1) {
            controller.state == .clarificationRequired(.missingSendRecipient)
                && synthesizer.spoken == ["Who should I send this to?"]
        }

        XCTAssertEqual(
            controller.state,
            .clarificationRequired(.missingSendRecipient)
        )
        XCTAssertEqual(synthesizer.spoken, ["Who should I send this to?"])
        XCTAssertEqual(capture.startCount, 1)

        synthesizer.finishSpeaking()
        await waitUntil(timeout: 1) {
            controller.state == .listening && capture.startCount == 2
        }

        let followUpGeneration = generator.expectPendingGeneration(
            "recipient follow-up generation registered"
        )
        capture.emitTranscript("John", isFinal: true)
        capture.emitStop(.silence)
        await fulfillment(of: [followUpGeneration], timeout: 1)
        XCTAssertEqual(
            generator.transcripts,
            ["Send him a message saying yes", "Send John a message saying yes"]
        )
        generator.completeNext(with: .success(Self.sendEnvelopeData(recipient: "John", body: "yes")))
        await fulfillment(of: [submitted], timeout: 1)
        await drainTasks()

        XCTAssertEqual(received.value?.intent, "send_message")
        XCTAssertEqual(received.value?.args["recipient"]?.stringValue, "John")
        XCTAssertEqual(received.value?.args["body"]?.stringValue, "yes")
        XCTAssertEqual(controller.state, .submitted("cmd_voice_1"))
        XCTAssertEqual(capture.startCount, 2)
    }

    func testSayHimAMessageAsksForNameThenMessageWithoutGenericCatch() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        synthesizer.completeImmediately = false
        let submitted = expectation(description: "submitted after say-him name and body")
        let received = VoiceTestBox<CommandEnvelope?>(nil)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer
        ) { envelope in
            received.value = envelope
            submitted.fulfill()
            return try Self.response()
        }

        let initialGeneration = generator.expectPendingGeneration(
            "say-him initial generation registered"
        )
        controller.start()
        capture.emitTranscript("Say him a message", isFinal: true)
        capture.emitStop(.finalTranscript)
        await fulfillment(of: [initialGeneration], timeout: 1)
        generator.completeNext(with: .failure(
            LocalCommandEnvelopeCanonicalizerError.clarificationRequired(
                .missingSendRecipient(body: "")
            )
        ))
        await drainTasks()

        XCTAssertEqual(
            controller.state,
            .clarificationRequired(.missingSendRecipient)
        )
        XCTAssertEqual(synthesizer.spoken, ["Who should I send this to?"])
        XCTAssertNotEqual(controller.state, .clarificationRequired(.generic))

        synthesizer.finishSpeaking()
        await waitUntil(timeout: 1) {
            controller.state == .listening && capture.startCount == 2
        }

        capture.emitTranscript("John", isFinal: true)
        capture.emitStop(.silence)
        await drainTasks()

        XCTAssertEqual(generator.transcripts, ["Say him a message"])
        XCTAssertEqual(
            controller.state,
            .clarificationRequired(.missingSendBody)
        )
        XCTAssertEqual(
            synthesizer.spoken,
            ["Who should I send this to?", "What should I say?"]
        )

        synthesizer.finishSpeaking()
        await waitUntil(timeout: 1) {
            controller.state == .listening
                && capture.startCount == 3
                && controller.followUpListenIsBody
        }

        let completedFollowUpGeneration = generator.expectPendingGeneration(
            "say-him completed follow-up generation registered"
        )
        capture.emitTranscript("yes", isFinal: true)
        capture.emitStop(.silence)
        await fulfillment(of: [completedFollowUpGeneration], timeout: 1)
        XCTAssertEqual(
            generator.transcripts,
            ["Say him a message", "Send John a message saying yes"]
        )
        generator.completeNext(with: .success(Self.sendEnvelopeData(recipient: "John", body: "yes")))
        await fulfillment(of: [submitted], timeout: 1)
        await drainTasks()

        XCTAssertEqual(received.value?.intent, "send_message")
        XCTAssertEqual(received.value?.args["recipient"]?.stringValue, "John")
        XCTAssertEqual(received.value?.args["body"]?.stringValue, "yes")
        XCTAssertEqual(controller.state, .submitted("cmd_voice_1"))
    }

    func testFollowUpDockReleaseDoesNotCutHandsFreeListenAndSendToNameFills() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        synthesizer.completeImmediately = false
        let submitted = expectation(description: "submitted after send-to name")
        let received = VoiceTestBox<CommandEnvelope?>(nil)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer
        ) { envelope in
            received.value = envelope
            submitted.fulfill()
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Send him a message saying yes", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            generator.transcripts == ["Send him a message saying yes"]
        }
        generator.completeNext(with: .failure(
            LocalCommandEnvelopeCanonicalizerError.clarificationRequired(
                .missingSendRecipient(body: "yes")
            )
        ))
        await drainTasks()
        await waitUntil(timeout: 1) {
            controller.state == .clarificationRequired(.missingSendRecipient)
                && synthesizer.spoken == ["Who should I send this to?"]
        }
        synthesizer.finishSpeaking()
        await waitUntil(timeout: 1) {
            controller.state == .listening && capture.startCount == 2
        }

        controller.stop()
        XCTAssertEqual(capture.stopCount, 0)
        XCTAssertEqual(controller.state, .listening)

        capture.emitTranscript("send to John", isFinal: true)
        capture.emitStop(.silence)
        await drainTasks()
        XCTAssertEqual(
            generator.transcripts,
            ["Send him a message saying yes", "Send John a message saying yes"]
        )
        generator.completeNext(with: .success(Self.sendEnvelopeData(recipient: "John", body: "yes")))
        await fulfillment(of: [submitted], timeout: 1)
        await drainTasks()

        XCTAssertEqual(received.value?.args["recipient"]?.stringValue, "John")
        XCTAssertEqual(controller.state, .submitted("cmd_voice_1"))
    }

    func testFollowUpSilenceKeepsPersonSlotAndDoesNotAutoListenAgain() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        synthesizer.completeImmediately = false
        let submitted = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer
        ) { _ in
            submitted.value = true
            return try Self.response()
        }

        let initialGeneration = generator.expectPendingGeneration(
            "pronoun follow-up initial generation registered"
        )
        controller.start()
        capture.emitTranscript("Send him a message saying yes", isFinal: true)
        capture.emitStop(.finalTranscript)
        await fulfillment(of: [initialGeneration], timeout: 1)
        generator.completeNext(with: .failure(
            LocalCommandEnvelopeCanonicalizerError.clarificationRequired(
                .missingSendRecipient(body: "yes")
            )
        ))
        await drainTasks()
        synthesizer.finishSpeaking()
        await waitUntil(timeout: 1) {
            controller.state == .listening && capture.startCount == 2
        }

        capture.emitStop(.noSpeech)
        await drainTasks()

        XCTAssertEqual(
            controller.state,
            .clarificationRequired(.missingSendRecipient)
        )
        XCTAssertFalse(submitted.value)
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertEqual(synthesizer.spoken, ["Who should I send this to?"])

        try? await Task.sleep(nanoseconds: 80_000_000)
        await drainTasks()
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertEqual(
            controller.state,
            .clarificationRequired(.missingSendRecipient)
        )
        XCTAssertFalse(submitted.value)
    }

    func testFollowUpPronounKeepsPersonSlotAndDoesNotAutoListenAgain() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        synthesizer.completeImmediately = false
        let submitted = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer
        ) { _ in
            submitted.value = true
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Send him a message saying yes", isFinal: true)
        capture.emitStop(.finalTranscript)
        await drainTasks()
        generator.completeNext(with: .failure(
            LocalCommandEnvelopeCanonicalizerError.clarificationRequired(
                .missingSendRecipient(body: "yes")
            )
        ))
        await drainTasks()
        synthesizer.finishSpeaking()
        await waitUntil(timeout: 1) {
            controller.state == .listening && capture.startCount == 2
        }

        capture.emitTranscript("him", isFinal: true)
        capture.emitStop(.silence)
        await drainTasks()

        XCTAssertEqual(
            controller.state,
            .clarificationRequired(.missingSendRecipient)
        )
        XCTAssertFalse(submitted.value)
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertEqual(generator.transcripts, ["Send him a message saying yes"])
        XCTAssertEqual(synthesizer.spoken, ["Who should I send this to?"])
    }

    func testFollowUpNoSpeechErrorRetriesListenThenFillsJohn() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        synthesizer.completeImmediately = false
        let submitted = expectation(description: "submitted after follow-up retry")
        let received = VoiceTestBox<CommandEnvelope?>(nil)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer
        ) { envelope in
            received.value = envelope
            submitted.fulfill()
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Send him a message saying yes", isFinal: true)
        capture.emitStop(.finalTranscript)
        await drainTasks()
        generator.completeNext(with: .failure(
            LocalCommandEnvelopeCanonicalizerError.clarificationRequired(
                .missingSendRecipient(body: "yes")
            )
        ))
        await drainTasks()
        synthesizer.finishSpeaking()
        await waitUntil(timeout: 1) {
            controller.state == .listening && capture.startCount == 2
        }

        capture.emitError(.noSpeechDetected)
        await waitUntil(timeout: 1) {
            controller.state == .listening && capture.startCount == 3
        }

        capture.emitTranscript("John", isFinal: true)
        capture.emitStop(.silence)
        await drainTasks()
        XCTAssertEqual(
            generator.transcripts,
            ["Send him a message saying yes", "Send John a message saying yes"]
        )
        generator.completeNext(with: .success(Self.sendEnvelopeData(recipient: "John", body: "yes")))
        await fulfillment(of: [submitted], timeout: 1)
        await drainTasks()

        XCTAssertEqual(received.value?.args["recipient"]?.stringValue, "John")
        XCTAssertEqual(controller.state, .submitted("cmd_voice_1"))
    }

    func testSecondFollowUpNoSpeechErrorStopsWithoutAnotherListen() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        synthesizer.completeImmediately = false
        let submitted = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer
        ) { _ in
            submitted.value = true
            return try Self.response()
        }

        let initialGeneration = generator.expectPendingGeneration(
            "second-follow-up initial generation registered"
        )
        controller.start()
        capture.emitTranscript("Send him a message saying yes", isFinal: true)
        capture.emitStop(.finalTranscript)
        await fulfillment(of: [initialGeneration], timeout: 1)
        generator.completeNext(with: .failure(
            LocalCommandEnvelopeCanonicalizerError.clarificationRequired(
                .missingSendRecipient(body: "yes")
            )
        ))
        await waitUntil(timeout: 1) {
            controller.state == .clarificationRequired(.missingSendRecipient)
                && synthesizer.spoken == ["Who should I send this to?"]
        }
        synthesizer.finishSpeaking()
        await waitUntil(timeout: 1) {
            controller.state == .listening && capture.startCount == 2
        }

        capture.emitError(.noSpeechDetected)
        await waitUntil(timeout: 1) {
            capture.startCount == 3
        }

        capture.emitError(.noSpeechDetected)
        await drainTasks()

        XCTAssertEqual(
            controller.state,
            .clarificationRequired(.missingSendRecipient)
        )
        XCTAssertFalse(submitted.value)
        XCTAssertEqual(capture.startCount, 3)
        if case let .failed(message) = controller.state {
            XCTFail("Follow-up listen must not ask the user to hold: \(message)")
        }
    }

    func testEmptyFirstUtteranceStillClarifiesWithoutAutoListen() async {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let submitted = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer
        ) { _ in
            submitted.value = true
            return try Self.response()
        }

        controller.start()
        capture.emitStop(.noSpeech)
        await drainTasks()

        XCTAssertEqual(controller.state, .clarificationRequired(.generic))
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertFalse(submitted.value)
        XCTAssertEqual(synthesizer.spoken, ["I didn't catch that."])
        XCTAssertEqual(capture.startCount, 1)
    }

    func testUnknownUtterancePostsAskWhenAgentIsSelected() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let asked = expectation(description: "posted ask")
        let received = VoiceTestBox<String?>(nil)
        let receivedTarget = VoiceTestBox<VoiceAskTarget?>(nil)
        let receivedClientTurnID = VoiceTestBox<String?>(nil)
        let targetResolutionCount = VoiceTestBox(0)
        let frozenTarget = VoiceAskTarget(
            agentID: "agt_apns",
            label: "apns-diagnostic",
            bindingID: "binding_original",
            leaseID: "lease_original",
            generation: 7,
            targetChatID: "chat_original"
        )
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: {
                targetResolutionCount.value += 1
                if targetResolutionCount.value == 1 {
                    return frozenTarget
                }
                return VoiceAskTarget(
                    agentID: "agt_changed",
                    label: "changed-agent",
                    bindingID: "binding_changed",
                    leaseID: "lease_changed",
                    generation: 8,
                    targetChatID: "chat_changed"
                )
            },
            submitAskWithTurnID: { transcript, target, clientTurnID in
                received.value = transcript
                receivedTarget.value = target
                receivedClientTurnID.value = clientTurnID
                asked.fulfill()
                return PhoneAskResponse(
                    ask_id: "ask_1",
                    agent_id: "agt_apns",
                    agent_label: "apns-diagnostic",
                    session_id: "ses_ask_1",
                    turn_sequence: 1,
                    status: "queued"
                )
            },
            streamAskResponses: { response, onResponse in
                XCTAssertEqual(response.session_id, "ses_ask_1")
                await onResponse("APNs is connected and ready.")
                return true
            }
        ) { _ in
            XCTFail("Local command must not be submitted for an agent ask")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Help with APNs", isFinal: true)
        capture.emitStop(.finalTranscript)
        await fulfillment(of: [asked], timeout: 1)
        await waitUntil(timeout: 1) {
            controller.state == .asked("apns-diagnostic")
        }

        XCTAssertEqual(received.value, "Help with APNs")
        XCTAssertEqual(receivedTarget.value, frozenTarget)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(receivedClientTurnID.value)))
        XCTAssertEqual(targetResolutionCount.value, 1)
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertEqual(controller.state, .asked("apns-diagnostic"))
        XCTAssertEqual(synthesizer.spoken, ["APNs is connected and ready."])
    }

    func testConcurrentBackgroundCaptureCallbacksProduceOneTerminalOutcome() async {
        let capture = ControlledVoiceCapture()
        let synthesizer = RecordingVoiceSynthesizer()
        let submissionCount = VoiceTestBox(0)
        let controller = makeController(
            generator: ControlledCommandGenerator(),
            capture: capture,
            synthesizer: synthesizer,
            askTarget: {
                VoiceAskTarget(agentID: "agt_codex", label: "Codex")
            },
            submitAsk: { _, target in
                submissionCount.value += 1
                return PhoneAskResponse(
                    ask_id: "ask_background",
                    agent_id: target.agentID,
                    agent_label: target.label,
                    session_id: "ses_background",
                    turn_sequence: 1,
                    status: "queued"
                )
            }
        ) { _ in
            XCTFail("Ask must not submit a local command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscriptFromBackground("Check the build", isFinal: true)
        await waitUntil(timeout: 1) {
            controller.transcript == "Check the build"
        }
        capture.emitConcurrentFinalStopsFromBackground()
        await waitUntil(timeout: 1) {
            controller.state == .asked("Codex")
        }
        await drainTasks()

        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(submissionCount.value, 1)
        XCTAssertEqual(controller.state, .asked("Codex"))
        XCTAssertEqual(synthesizer.spoken, ["Sent to Codex."])
    }

    func testStaleOldTurnAskCompletionCannotChangeNewerTurn() async {
        let capture = ControlledVoiceCapture()
        let synthesizer = RecordingVoiceSynthesizer()
        let firstAskStarted = expectation(description: "first ask started")
        let firstAskReturned = expectation(description: "first ask returned")
        let firstRelease = VoiceTestBox<CheckedContinuation<Void, Never>?>(nil)
        let submissionCount = VoiceTestBox(0)
        let targetCount = VoiceTestBox(0)
        let clientTurnIDs = VoiceTestBox<[String]>([])
        let controller = makeController(
            generator: ControlledCommandGenerator(),
            capture: capture,
            synthesizer: synthesizer,
            askTarget: {
                targetCount.value += 1
                let suffix = targetCount.value == 1 ? "old" : "new"
                return VoiceAskTarget(
                    agentID: "agt_\(suffix)",
                    label: "\(suffix)-codex"
                )
            },
            submitAskWithTurnID: { _, target, clientTurnID in
                submissionCount.value += 1
                clientTurnIDs.value.append(clientTurnID)
                if submissionCount.value == 1 {
                    await withCheckedContinuation { continuation in
                        firstRelease.value = continuation
                        firstAskStarted.fulfill()
                    }
                    firstAskReturned.fulfill()
                }
                return PhoneAskResponse(
                    ask_id: "ask_\(submissionCount.value)",
                    agent_id: target.agentID,
                    agent_label: target.label,
                    session_id: "ses_\(submissionCount.value)",
                    turn_sequence: submissionCount.value,
                    status: "queued"
                )
            }
        ) { _ in
            XCTFail("Ask must not submit a local command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("first request", isFinal: true)
        capture.emitStop(.finalTranscript)
        await fulfillment(of: [firstAskStarted], timeout: 1)

        controller.cancel()
        controller.start()
        capture.emitTranscript("second request", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            controller.state == .asked("new-codex")
        }
        let newerTurnSpeech = synthesizer.spoken

        let continuation = firstRelease.value
        firstRelease.value = nil
        continuation?.resume()
        await fulfillment(of: [firstAskReturned], timeout: 1)
        await drainTasks()

        XCTAssertEqual(clientTurnIDs.value.count, 2)
        XCTAssertNotEqual(clientTurnIDs.value[0], clientTurnIDs.value[1])
        XCTAssertEqual(controller.state, .asked("new-codex"))
        XCTAssertEqual(synthesizer.spoken, newerTurnSpeech)
        XCTAssertEqual(synthesizer.spoken, ["Sent to new-codex."])
    }

    func testTransientAskTimeoutReconcilesWithSameClientTurnID() async throws {
        let capture = ControlledVoiceCapture()
        let synthesizer = RecordingVoiceSynthesizer()
        let attempts = VoiceTestBox<[(String, VoiceAskTarget, String)]>([])
        let targetResolutionCount = VoiceTestBox(0)
        let frozenTarget = VoiceAskTarget(
            agentID: "agt_codex",
            label: "Codex",
            bindingID: "binding_1",
            leaseID: "lease_1",
            generation: 4,
            targetChatID: "chat_1"
        )
        let controller = makeController(
            generator: ControlledCommandGenerator(),
            capture: capture,
            synthesizer: synthesizer,
            askTarget: {
                targetResolutionCount.value += 1
                return frozenTarget
            },
            submitAskWithTurnID: { transcript, target, clientTurnID in
                attempts.value.append((transcript, target, clientTurnID))
                if attempts.value.count == 1 {
                    throw APIClientError.network("The request timed out.")
                }
                return PhoneAskResponse(
                    ask_id: "ask_reused",
                    agent_id: target.agentID,
                    agent_label: target.label,
                    session_id: "ses_reused",
                    turn_sequence: 1,
                    status: "queued"
                )
            }
        ) { _ in
            XCTFail("Ask must not submit a local command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Check the build", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            controller.state == .asked("Codex")
        }

        XCTAssertEqual(attempts.value.count, 2)
        XCTAssertEqual(attempts.value.map(\.0), ["Check the build", "Check the build"])
        XCTAssertEqual(attempts.value.map(\.1), [frozenTarget, frozenTarget])
        XCTAssertEqual(Set(attempts.value.map(\.2)).count, 1)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(attempts.value.first?.2)))
        XCTAssertEqual(targetResolutionCount.value, 1)
        XCTAssertEqual(synthesizer.spoken, ["Sent to Codex."])
    }

    func testInFlightAndAcceptedAskSuppressLateCaptureFailure() async {
        let capture = ControlledVoiceCapture()
        let synthesizer = RecordingVoiceSynthesizer()
        let askStarted = expectation(description: "ask in flight")
        let releaseAsk = VoiceTestBox<CheckedContinuation<Void, Never>?>(nil)
        let controller = makeController(
            generator: ControlledCommandGenerator(),
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_codex", label: "Codex") },
            submitAsk: { _, target in
                await withCheckedContinuation { continuation in
                    releaseAsk.value = continuation
                    askStarted.fulfill()
                }
                return PhoneAskResponse(
                    ask_id: "ask_accepted",
                    agent_id: target.agentID,
                    agent_label: target.label,
                    session_id: "ses_accepted",
                    turn_sequence: 1,
                    status: "queued"
                )
            }
        ) { _ in
            XCTFail("Ask must not submit a local command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Check Codex", isFinal: true)
        capture.emitStop(.finalTranscript)
        await fulfillment(of: [askStarted], timeout: 1)

        capture.emitError(.noSpeechDetected)
        await drainTasks()
        XCTAssertEqual(controller.state, .asking("Codex"))
        XCTAssertTrue(synthesizer.spoken.isEmpty)

        let continuation = releaseAsk.value
        releaseAsk.value = nil
        continuation?.resume()
        await waitUntil(timeout: 1) {
            controller.state == .asked("Codex")
        }

        capture.emitError(.recognitionFailure)
        capture.emitStop(.noSpeech)
        await drainTasks()
        XCTAssertEqual(controller.state, .asked("Codex"))
        XCTAssertEqual(synthesizer.spoken, ["Sent to Codex."])
        XCTAssertFalse(synthesizer.spoken.contains("I didn't catch that."))
    }

    func testDuplicateAskResponseCallbacksSpeakOneTerminalMessage() async {
        let capture = ControlledVoiceCapture()
        let synthesizer = RecordingVoiceSynthesizer()
        let controller = makeController(
            generator: ControlledCommandGenerator(),
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_codex", label: "Codex") },
            submitAsk: { _, target in
                PhoneAskResponse(
                    ask_id: "ask_duplicate_stream",
                    agent_id: target.agentID,
                    agent_label: target.label,
                    session_id: "ses_duplicate_stream",
                    turn_sequence: 1,
                    status: "queued"
                )
            },
            streamAskResponses: { _, onResponse in
                await onResponse("The build passed.")
                await onResponse("The build passed.")
                return true
            }
        ) { _ in
            XCTFail("Ask must not submit a local command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Did the build pass?", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            controller.state == .asked("Codex")
        }

        XCTAssertEqual(synthesizer.spoken, ["The build passed."])
    }

    func testRepeatedTransientAskFailureShowsOneDeliveryRetryMessage() async {
        let capture = ControlledVoiceCapture()
        let synthesizer = RecordingVoiceSynthesizer()
        let attempts = VoiceTestBox<[String]>([])
        let controller = makeController(
            generator: ControlledCommandGenerator(),
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_codex", label: "Codex") },
            submitAskWithTurnID: { _, _, clientTurnID in
                attempts.value.append(clientTurnID)
                throw APIClientError.network("The request timed out.")
            }
        ) { _ in
            XCTFail("Ask must not submit a local command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Check the build", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            controller.state == .failed(
                LocalVoiceCommandControllerError.deliveryUnconfirmed.localizedDescription
            )
        }

        capture.emitError(.noSpeechDetected)
        capture.emitStop(.noSpeech)
        await drainTasks()

        XCTAssertEqual(attempts.value.count, 2)
        XCTAssertEqual(Set(attempts.value).count, 1)
        XCTAssertEqual(
            synthesizer.spoken,
            [LocalVoiceCommandControllerError.deliveryUnconfirmed.localizedDescription]
        )
    }

    func testAskResponseMissingSessionReleasesDockWithoutSuccessSpeech() async {
        await assertMalformedAskResponseReleasesDock(PhoneAskResponse(
            ask_id: "ask_missing_session",
            agent_id: "agt_codex",
            agent_label: "Codex",
            session_id: nil,
            turn_sequence: 1,
            status: "queued"
        ))
    }

    func testAskResponseMissingTurnSequenceReleasesDockWithoutSuccessSpeech() async {
        await assertMalformedAskResponseReleasesDock(PhoneAskResponse(
            ask_id: "ask_missing_turn",
            agent_id: "agt_codex",
            agent_label: "Codex",
            session_id: "ses_missing_turn",
            turn_sequence: nil,
            status: "queued"
        ))
    }

    func testAskResponseAgentMismatchReleasesDockWithoutSuccessSpeech() async {
        await assertMalformedAskResponseReleasesDock(PhoneAskResponse(
            ask_id: "ask_agent_mismatch",
            agent_id: "agt_other",
            agent_label: "Other",
            session_id: "ses_agent_mismatch",
            turn_sequence: 1,
            status: "queued"
        ))
    }

    func testMalformedAskResponseAllowsNextCaptureStart() async {
        let capture = ControlledVoiceCapture()
        let synthesizer = RecordingVoiceSynthesizer()
        let attempts = VoiceTestBox(0)
        let controller = makeController(
            generator: ControlledCommandGenerator(),
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_codex", label: "Codex") },
            submitAsk: { _, _ in
                attempts.value += 1
                return PhoneAskResponse(
                    ask_id: "ask_next_start",
                    agent_id: "agt_codex",
                    agent_label: "Codex",
                    session_id: nil,
                    turn_sequence: 1,
                    status: "queued"
                )
            }
        ) { _ in
            XCTFail("Ask must not submit a local command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Check the build", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            controller.state == .failed(
                LocalVoiceCommandControllerError.deliveryUnconfirmed.localizedDescription
            )
        }
        XCTAssertEqual(attempts.value, 2)

        controller.start()

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertEqual(
            synthesizer.spoken,
            [LocalVoiceCommandControllerError.deliveryUnconfirmed.localizedDescription]
        )
    }

    func testChineseUnknownUtterancePostsAsk() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let asked = expectation(description: "posted chinese ask")
        let received = VoiceTestBox<String?>(nil)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_apns", label: "cursor-staging") },
            submitAsk: { transcript, _ in
                received.value = transcript
                asked.fulfill()
                return PhoneAskResponse(
                    ask_id: "ask_zh",
                    agent_id: "agt_apns",
                    agent_label: "cursor-staging",
                    session_id: "ses_ask_zh",
                    turn_sequence: 1,
                    status: "queued"
                )
            }
        ) { _ in
            XCTFail("Chinese ask must not become a local command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("今天天气怎么样", isFinal: true)
        capture.emitStop(.finalTranscript)
        await fulfillment(of: [asked], timeout: 1)
        await waitUntil(timeout: 1) {
            controller.state == .asked("cursor-staging")
        }

        XCTAssertEqual(received.value, "今天天气怎么样")
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertEqual(controller.state, .asked("cursor-staging"))
        XCTAssertEqual(synthesizer.spoken, ["Sent to cursor-staging."])
    }

    func testChineseShortcutUtterancePostsAskInsteadOfLocalClassification() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let asked = expectation(description: "posted chinese shortcut as ask")
        let received = VoiceTestBox<String?>(nil)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_apns", label: "cursor-staging") },
            submitAsk: { transcript, _ in
                received.value = transcript
                asked.fulfill()
                return PhoneAskResponse(
                    ask_id: "ask_zh_send",
                    agent_id: "agt_apns",
                    agent_label: "cursor-staging",
                    session_id: "ses_ask_zh_send",
                    turn_sequence: 1,
                    status: "queued"
                )
            }
        ) { _ in
            XCTFail("Chinese speech must not be classified into a local command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("发消息给 John 说你好", isFinal: true)
        capture.emitStop(.finalTranscript)
        await fulfillment(of: [asked], timeout: 1)
        await waitUntil(timeout: 1) {
            controller.state == .asked("cursor-staging")
        }

        XCTAssertEqual(received.value, "发消息给 John 说你好")
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertEqual(controller.state, .asked("cursor-staging"))
    }

    func testUnsupportedLocalIntentHandsOffToAskInsteadOfClassifying() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let asked = expectation(description: "handed off to ask")
        let received = VoiceTestBox<String?>(nil)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_apns", label: "cursor-staging") },
            submitAsk: { transcript, _ in
                received.value = transcript
                asked.fulfill()
                return PhoneAskResponse(
                    ask_id: "ask_handoff",
                    agent_id: "agt_apns",
                    agent_label: "cursor-staging",
                    session_id: "ses_ask_handoff",
                    turn_sequence: 1,
                    status: "queued"
                )
            }
        ) { _ in
            XCTFail("Unsupported local intent must not POST a phone command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Remind me tomorrow at 9 AM to call John", isFinal: true)
        capture.emitStop(.finalTranscript)
        await drainTasks()
        XCTAssertEqual(controller.state, .processing)
        generator.completeNext(with: .failure(
            LocalCommandEnvelopeCanonicalizerError.clarificationRequired(.unsupportedIntent)
        ))
        await fulfillment(of: [asked], timeout: 1)
        await waitUntil(timeout: 1) {
            controller.state == .asked("cursor-staging")
        }

        XCTAssertEqual(received.value, "Remind me tomorrow at 9 AM to call John")
        XCTAssertEqual(controller.state, .asked("cursor-staging"))
        XCTAssertEqual(synthesizer.spoken, ["Sent to cursor-staging."])
    }

    func testUnknownUtteranceWithoutSelectedAgentAsksUserToSelectOne() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let submitted = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            submitAsk: { _, _ in
                XCTFail("Ask must not POST when no agent is selected")
                return PhoneAskResponse(
                    ask_id: "ask_should_not_fire",
                    agent_id: "agt_none",
                    agent_label: nil,
                    session_id: nil,
                    status: "queued"
                )
            }
        ) { _ in
            submitted.value = true
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Help with APNs", isFinal: true)
        capture.emitStop(.finalTranscript)
        await drainTasks()

        XCTAssertEqual(controller.state, .clarificationRequired(.selectAgent))
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertFalse(submitted.value)
        XCTAssertEqual(synthesizer.spoken, ["Select an agent first."])
    }

    func testAskFailsClosedWhenAgentIsNotListening() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_apns", label: "apns-diagnostic") },
            submitAsk: { _, _ in
                throw APIClientError.badStatus(
                    409,
                    "The selected agent is not listening.",
                    APIErrorMetadata(
                        retryable: false,
                        retryAfter: nil,
                        requestID: nil,
                        errorCode: "agent_not_listening"
                    )
                )
            }
        ) { _ in
            XCTFail("Local command must not be submitted when the agent is not listening")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Help with APNs", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            controller.state == .clarificationRequired(.agentNotListening)
        }

        XCTAssertEqual(controller.state, .clarificationRequired(.agentNotListening))
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertEqual(synthesizer.spoken, ["apns-diagnostic is not listening."])
    }

    func testAskFenceMismatchRequiresSelectionWithoutRerouting() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let targetResolutionCount = VoiceTestBox(0)
        let submissionCount = VoiceTestBox(0)
        let frozenTarget = VoiceAskTarget(
            agentID: "agt_apns",
            label: "apns-diagnostic",
            bindingID: "binding_1",
            leaseID: "lease_1",
            generation: 7,
            targetChatID: "chat_1"
        )
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: {
                targetResolutionCount.value += 1
                return frozenTarget
            },
            submitAsk: { _, target in
                submissionCount.value += 1
                XCTAssertEqual(target, frozenTarget)
                throw APIClientError.badStatus(
                    409,
                    "The listener fence is no longer active.",
                    APIErrorMetadata(
                        retryable: false,
                        retryAfter: nil,
                        requestID: nil,
                        errorCode: "ask_listener_fence_mismatch"
                    )
                )
            }
        ) { _ in
            XCTFail("A fenced Ask must not fall back to local command submission")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Help with APNs", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            controller.state == .clarificationRequired(.selectAgent)
        }

        XCTAssertEqual(targetResolutionCount.value, 1)
        XCTAssertEqual(submissionCount.value, 1)
        XCTAssertEqual(controller.state, .clarificationRequired(.selectAgent))
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertEqual(
            synthesizer.spoken,
            ["The listener changed. Select the agent again."]
        )
    }

    func testIncompleteSendStaysLocalEvenWhenAnAgentIsSelected() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        generator.cannedResult = .failure(
            LocalCommandEnvelopeCanonicalizerError.clarificationRequired(
                .missingSendRecipient(body: "")
            )
        )
        let synthesizer = RecordingVoiceSynthesizer()
        synthesizer.completeImmediately = false
        let asked = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_apns", label: "apns-diagnostic") },
            submitAsk: { _, _ in
                asked.value = true
                return PhoneAskResponse(
                    ask_id: "ask_should_not_fire",
                    agent_id: "agt_apns",
                    agent_label: "apns-diagnostic",
                    session_id: nil,
                    status: "queued"
                )
            }
        ) { _ in
            XCTFail("Incomplete send must ask for a name instead of submitting")
            return try Self.response()
        }

        XCTAssertTrue(
            LocalVoiceUtterancePreflight.prefersLocalCommandPath(for: "Say him a message")
        )

        controller.start()
        capture.emitTranscript("Say him a message", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            controller.state == .clarificationRequired(.missingSendRecipient)
        }

        XCTAssertEqual(controller.state, .clarificationRequired(.missingSendRecipient))
        XCTAssertNotEqual(controller.state, .processing)
        XCTAssertNotEqual(controller.state, .asking("apns-diagnostic"))
        XCTAssertNotEqual(controller.state, .asked("apns-diagnostic"))
        XCTAssertFalse(asked.value)
        XCTAssertEqual(generator.transcripts, ["Say him a message"])
        XCTAssertEqual(synthesizer.spoken, ["Who should I send this to?"])

        let copy = HomeVoiceDockCopy.make(
            voice: controller.state,
            isFollowUpListen: controller.isFollowUpListen,
            targetLabel: "apns-diagnostic",
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(copy.title, "Don’t press")
        XCTAssertEqual(copy.status, "Say a name")
    }

    func testAskPollDeadlineReleasesDockAsWaitingWithoutCaptureFailure() async {
        let capture = ControlledVoiceCapture()
        let synthesizer = RecordingVoiceSynthesizer()
        let controller = makeController(
            generator: ControlledCommandGenerator(),
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_codex", label: "Codex") },
            submitAsk: { _, target in
                PhoneAskResponse(
                    ask_id: "ask_delayed",
                    agent_id: target.agentID,
                    agent_label: target.label,
                    session_id: "ses_delayed",
                    turn_sequence: 10,
                    status: "queued"
                )
            },
            streamAskResponses: { _, _ in
                // Deterministic stand-in for the elapsed 45-second foreground window.
                false
            }
        ) { _ in
            XCTFail("Ask must not submit a local command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Did the build pass?", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            controller.state == .asked("Codex")
        }

        XCTAssertEqual(controller.state, .asked("Codex"))
        XCTAssertEqual(synthesizer.spoken, ["Sent to Codex."])
        XCTAssertFalse(synthesizer.spoken.contains("I didn't catch that."))

        controller.start()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(capture.startCount, 2)
    }

    private func assertMalformedAskResponseReleasesDock(
        _ response: PhoneAskResponse
    ) async {
        let capture = ControlledVoiceCapture()
        let synthesizer = RecordingVoiceSynthesizer()
        let attempts = VoiceTestBox(0)
        let controller = makeController(
            generator: ControlledCommandGenerator(),
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_codex", label: "Codex") },
            submitAsk: { _, _ in
                attempts.value += 1
                return response
            }
        ) { _ in
            XCTFail("Ask must not submit a local command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Check the build", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            controller.state == .failed(
                LocalVoiceCommandControllerError.deliveryUnconfirmed.localizedDescription
            )
        }

        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(
            controller.state,
            .failed(LocalVoiceCommandControllerError.deliveryUnconfirmed.localizedDescription)
        )
        XCTAssertEqual(
            synthesizer.spoken,
            [LocalVoiceCommandControllerError.deliveryUnconfirmed.localizedDescription]
        )
        XCTAssertFalse(synthesizer.spoken.contains { $0.hasPrefix("Sent to ") })
    }

    func testRetryAdoptsAlreadyAcceptedWithoutDuplicatePostOrFalseFailure() async {
        let capture = ControlledVoiceCapture()
        let synthesizer = RecordingVoiceSynthesizer()
        let attempts = VoiceTestBox(0)
        let backendPosts = VoiceTestBox(0)
        let streamCount = VoiceTestBox(0)
        let clientTurnIDs = VoiceTestBox<[String]>([])
        let controller = makeController(
            generator: ControlledCommandGenerator(),
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_codex", label: "Codex") },
            submitAskOutcomeWithTurnID: { _, target, clientTurnID in
                attempts.value += 1
                clientTurnIDs.value.append(clientTurnID)
                if attempts.value == 1 {
                    backendPosts.value += 1
                    throw APIClientError.network("The accepted response was lost.")
                }
                return .alreadyAccepted(PhoneAskResponse(
                    ask_id: "ask_apns_accepted",
                    agent_id: target.agentID,
                    agent_label: target.label,
                    session_id: "ses_apns_accepted",
                    turn_sequence: 41,
                    status: "queued"
                ))
            },
            streamAskResponses: { response, _ in
                streamCount.value += 1
                XCTAssertEqual(response.ask_id, "ask_apns_accepted")
                return false
            }
        ) { _ in
            XCTFail("Ask must not submit a local command")
            return try Self.response()
        }

        controller.start()
        let baselineStopCount = synthesizer.stopCount
        capture.emitTranscript("Did the build pass?", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            controller.state == .asked("Codex")
                && synthesizer.spoken.filter { $0.hasPrefix("Sent to ") }.count == 1
        }

        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(backendPosts.value, 1)
        XCTAssertEqual(Set(clientTurnIDs.value).count, 1)
        XCTAssertEqual(streamCount.value, 1)
        XCTAssertEqual(controller.state, .asked("Codex"))
        XCTAssertEqual(synthesizer.stopCount, baselineStopCount)
        XCTAssertEqual(synthesizer.spoken.filter { $0.hasPrefix("Sent to ") }.count, 1)
        XCTAssertFalse(synthesizer.spoken.contains(
            LocalVoiceCommandControllerError.deliveryUnconfirmed.localizedDescription
        ))
    }

    func testRetryAdoptsAlreadyReconciledWhileCanonicalPresentationOwnsSpeech() async {
        let capture = ControlledVoiceCapture()
        let synthesizer = RecordingVoiceSynthesizer()
        let attempts = VoiceTestBox(0)
        let backendPosts = VoiceTestBox(0)
        let canonicalPresentationStarted = VoiceTestBox(false)
        let stopCountAtCanonicalStart = VoiceTestBox<Int?>(nil)
        let controller = makeController(
            generator: ControlledCommandGenerator(),
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_codex", label: "Codex") },
            submitAskOutcomeWithTurnID: { _, _, _ in
                attempts.value += 1
                if attempts.value == 1 {
                    backendPosts.value += 1
                    throw APIClientError.network("The accepted response was lost.")
                }
                canonicalPresentationStarted.value = true
                stopCountAtCanonicalStart.value = await MainActor.run {
                    synthesizer.stopCount
                }
                await Task.yield()
                return .alreadyReconciled
            },
            streamAskResponses: { _, _ in
                XCTFail("Coordinator-owned canonical presentation must not start a second stream")
                return false
            }
        ) { _ in
            XCTFail("Ask must not submit a local command")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Did the build pass?", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            canonicalPresentationStarted.value && controller.state == .asked("Codex")
        }

        XCTAssertEqual(attempts.value, 2)
        XCTAssertEqual(backendPosts.value, 1)
        XCTAssertEqual(controller.state, .asked("Codex"))
        XCTAssertEqual(synthesizer.stopCount, stopCountAtCanonicalStart.value)
        XCTAssertTrue(synthesizer.spoken.isEmpty)
        XCTAssertFalse(synthesizer.spoken.contains(
            LocalVoiceCommandControllerError.deliveryUnconfirmed.localizedDescription
        ))
    }

    private func makeController(
        generator: ControlledCommandGenerator,
        capture: ControlledVoiceCapture,
        synthesizer: RecordingVoiceSynthesizer = RecordingVoiceSynthesizer(),
        generationTimeoutNanoseconds: UInt64 = 15_000_000_000,
        askTarget: @escaping () -> VoiceAskTarget? = { nil },
        submitAskWithTurnID: (
            @Sendable (String, VoiceAskTarget, String) async throws -> PhoneAskResponse
        )? = nil,
        submitAskOutcomeWithTurnID: (
            @Sendable (String, VoiceAskTarget, String) async throws -> PhoneAskSubmissionOutcome
        )? = nil,
        submitAsk: (@Sendable (String, VoiceAskTarget) async throws -> PhoneAskResponse)? = nil,
        streamAskResponses: (
            @Sendable (
                PhoneAskResponse,
                @escaping @Sendable (String) async -> Void
            ) async throws -> Bool
        )? = nil,
        submit: @escaping @Sendable (CommandEnvelope) async throws -> CommandResponse
    ) -> LocalVoiceCommandController {
        let adaptedSubmitAsk: (
            @Sendable (String, VoiceAskTarget, String) async throws -> PhoneAskResponse
        )?
        if let submitAskWithTurnID {
            adaptedSubmitAsk = submitAskWithTurnID
        } else if let submitAsk {
            adaptedSubmitAsk = { transcript, target, _ in
                try await submitAsk(transcript, target)
            }
        } else {
            adaptedSubmitAsk = nil
        }
        return LocalVoiceCommandController(
            generator: generator,
            submit: submit,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: askTarget,
            submitAsk: adaptedSubmitAsk,
            submitAskOutcome: submitAskOutcomeWithTurnID,
            streamAskResponses: streamAskResponses,
            permissionsAreGranted: { true },
            requestPermissions: { _ in
                XCTFail("Permissions should not be requested in this test")
            },
            generationTimeoutNanoseconds: generationTimeoutNanoseconds,
            followUpListenDelayNanoseconds: 0
        )
    }

    private func drainTasks(iterations: Int = 5) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if !predicate() {
            XCTFail("Condition was not met before timeout", file: file, line: line)
        }
    }

    private nonisolated static func sendEnvelopeData(recipient: String, body: String) -> Data {
        Data("""
        {
          "schema_version": 1,
          "command_id": "cmd_voice_1",
          "intent": "send_message",
          "args": {"recipient": "\(recipient)", "body": "\(body)"},
          "risk_level": "high",
          "needs_confirmation": true,
          "idempotency_key": "idem_voice_1",
          "confidence": 1.0,
          "locale": "en-HK",
          "timezone": "Asia/Hong_Kong"
        }
        """.utf8)
    }

    private nonisolated static func envelopeData(query: String) -> Data {
        Data("""
        {
          "schema_version": 1,
          "command_id": "cmd_voice_1",
          "intent": "search_history",
          "args": {"q": "\(query)"},
          "risk_level": "low",
          "needs_confirmation": false,
          "idempotency_key": "idem_voice_1",
          "confidence": 0.96,
          "locale": "zh-Hans-HK",
          "timezone": "Asia/Hong_Kong"
        }
        """.utf8)
    }

    private nonisolated static func response() throws -> CommandResponse {
        let envelope = try CommandEnvelope(
            commandID: "cmd_voice_1",
            intent: "search_history",
            args: ["q": .string("history")],
            riskLevel: .low,
            needsConfirmation: false,
            idempotencyKey: "idem_voice_1",
            confidence: 0.96,
            locale: "zh-Hans-HK",
            timezone: "Asia/Hong_Kong"
        )
        return CommandResponse(
            command_id: "cmd_voice_1",
            state: "queued",
            command: envelope,
            action: nil,
            presentation: nil,
            confirmation_token: nil,
            result: nil,
            error: nil,
            undo_command_id: nil,
            version: 2,
            created_at: nil,
            updated_at: nil
        )
    }
}

private extension JSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}

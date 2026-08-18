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
    private(set) var transcripts: [String] = []
    private(set) var cancelCount = 0
    var onGenerate: (() -> Void)?
    private var completions: [(Result<Data, Error>) -> Void] = []

    func generateCommand(for transcript: String, completion: @escaping (Result<Data, Error>) -> Void) {
        transcripts.append(transcript)
        completions.append(completion)
        onGenerate?()
    }

    func completeNext(with result: Result<Data, Error>) {
        guard !completions.isEmpty else {
            XCTFail("No pending generation")
            return
        }
        completions.removeFirst()(result)
    }

    func cancelGeneration() {
        guard !completions.isEmpty else { return }
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
        await drainTasks()
        generator.completeNext(with: .failure(
            LocalCommandEnvelopeCanonicalizerError.clarificationRequired(.lowConfidence)
        ))
        await drainTasks()

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

        controller.start()
        capture.emitTranscript("Say him a message", isFinal: true)
        capture.emitStop(.finalTranscript)
        await drainTasks()
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

        capture.emitTranscript("yes", isFinal: true)
        capture.emitStop(.silence)
        await drainTasks()
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

        capture.emitTranscript("John", isFinal: false)
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
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_apns", label: "apns-diagnostic") },
            submitAsk: { transcript in
                received.value = transcript
                asked.fulfill()
                return PhoneAskResponse(
                    ask_id: "ask_1",
                    agent_id: "agt_apns",
                    agent_label: "apns-diagnostic",
                    session_id: "ses_ask_1",
                    status: "queued"
                )
            }
        ) { _ in
            XCTFail("Local command must not be submitted for an agent ask")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Help with APNs", isFinal: true)
        capture.emitStop(.finalTranscript)
        await fulfillment(of: [asked], timeout: 1)
        await drainTasks()

        XCTAssertEqual(received.value, "Help with APNs")
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertEqual(controller.state, .asked("apns-diagnostic"))
        XCTAssertEqual(synthesizer.spoken, ["Asked apns-diagnostic."])
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
            submitAsk: { _ in
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
            submitAsk: { _ in
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

    func testIncompleteSendStaysLocalEvenWhenAnAgentIsSelected() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        synthesizer.completeImmediately = false
        let asked = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { VoiceAskTarget(agentID: "agt_apns", label: "apns-diagnostic") },
            submitAsk: { _ in
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

        controller.start()
        capture.emitTranscript("Say him a message", isFinal: true)
        capture.emitStop(.finalTranscript)
        await drainTasks()
        generator.completeNext(with: .failure(
            LocalCommandEnvelopeCanonicalizerError.clarificationRequired(
                .missingSendRecipient(body: "")
            )
        ))
        await drainTasks()

        XCTAssertEqual(controller.state, .clarificationRequired(.missingSendRecipient))
        XCTAssertFalse(asked.value)
        XCTAssertEqual(generator.transcripts, ["Say him a message"])
        XCTAssertEqual(synthesizer.spoken, ["Who should I send this to?"])
    }

    private func makeController(
        generator: ControlledCommandGenerator,
        capture: ControlledVoiceCapture,
        synthesizer: RecordingVoiceSynthesizer = RecordingVoiceSynthesizer(),
        generationTimeoutNanoseconds: UInt64 = 15_000_000_000,
        askTarget: @escaping () -> VoiceAskTarget? = { nil },
        submitAsk: (@Sendable (String) async throws -> PhoneAskResponse)? = nil,
        submit: @escaping @Sendable (CommandEnvelope) async throws -> CommandResponse
    ) -> LocalVoiceCommandController {
        LocalVoiceCommandController(
            generator: generator,
            submit: submit,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: askTarget,
            submitAsk: submitAsk,
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

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

    func speak(
        _ text: String,
        completion: @escaping (VoiceSynthesisResult) -> Void
    ) {
        spoken.append(text)
        completion(.finished)
    }

    func stop() {
        stopCount += 1
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

        XCTAssertEqual(controller.state, .clarificationRequired)
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertFalse(submitted.value)
        XCTAssertEqual(synthesizer.spoken, ["Could you clarify that?"])
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
        XCTAssertEqual(controller.state, .clarificationRequired)
        XCTAssertEqual(synthesizer.spoken, ["Could you clarify that?"])
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
        XCTAssertEqual(controller.state, .clarificationRequired)
        XCTAssertEqual(synthesizer.spoken, ["Could you clarify that?"])
    }

    private func makeController(
        generator: ControlledCommandGenerator,
        capture: ControlledVoiceCapture,
        synthesizer: RecordingVoiceSynthesizer = RecordingVoiceSynthesizer(),
        submit: @escaping @Sendable (CommandEnvelope) async throws -> CommandResponse
    ) -> LocalVoiceCommandController {
        LocalVoiceCommandController(
            generator: generator,
            submit: submit,
            capture: capture,
            synthesizer: synthesizer,
            permissionsAreGranted: { true },
            requestPermissions: { _ in
                XCTFail("Permissions should not be requested in this test")
            }
        )
    }

    private func drainTasks(iterations: Int = 5) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
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

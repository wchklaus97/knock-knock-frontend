import XCTest
@testable import VoiceAgentBridge

private final class RecordingVoiceSynthesizer: VoiceSynthesizing {
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0
    private(set) var pendingCompletionCount = 0
    private let automaticallyCompletes: Bool
    private var completions: [(VoiceSynthesisResult) -> Void] = []
    var onStop: (() -> Void)?

    init(automaticallyCompletes: Bool = true) {
        self.automaticallyCompletes = automaticallyCompletes
    }

    func speak(
        _ text: String,
        completion: @escaping (VoiceSynthesisResult) -> Void
    ) {
        spoken.append(text)
        if automaticallyCompletes {
            completion(.finished)
        } else {
            completions.append(completion)
            pendingCompletionCount = completions.count
        }
    }

    func stop() {
        stopCount += 1
        onStop?()
        let pending = completions
        completions.removeAll()
        pendingCompletionCount = 0
        pending.forEach { $0(.cancelled) }
    }

    func finishNext() {
        guard !completions.isEmpty else {
            XCTFail("No pending synthesis")
            return
        }
        let completion = completions.removeFirst()
        pendingCompletionCount = completions.count
        completion(.finished)
    }
}

private final class APIErrorURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class BackendCommandPresentationTests: XCTestCase {
    func testCanonicalServerPresentationIsUsed() throws {
        let server = Self.presentation(
            displayText: "Message saved to the local outbox; external delivery is not confirmed.",
            voiceScript: "Message queued locally.",
            terminal: true
        )
        let response = try Self.response(
            state: "succeeded",
            result: .object([
                "kind": .string("message"),
                "voice_script": .string("MODEL CONTROLLED SECRET"),
            ]),
            args: ["body": .string("private body")],
            presentation: server
        )

        let presentation = BackendCommandPresentation(response: response)

        XCTAssertTrue(presentation.isServerValidated)
        XCTAssertTrue(presentation.isTerminal)
        XCTAssertEqual(presentation.message, server.display_text)
        XCTAssertEqual(presentation.voiceScript, server.voice_script)
        XCTAssertFalse(presentation.message.contains("private body"))
        XCTAssertFalse(presentation.message.contains("MODEL CONTROLLED SECRET"))
    }

    func testQueuedPresentationCanBeCancelledAndRunningCannot() throws {
        let queued = BackendCommandPresentation(
            response: try Self.response(state: "queued", result: nil, version: 2)
        )
        XCTAssertTrue(queued.isCancellable)
        XCTAssertFalse(queued.isTerminal)
        XCTAssertEqual(queued.nextStepHint, "Cancel to speak another command.")

        let awaiting = BackendCommandPresentation(
            response: try Self.response(state: "awaiting_confirmation", result: nil, version: 1)
        )
        XCTAssertTrue(awaiting.isCancellable)
        XCTAssertEqual(awaiting.nextStepHint, "Confirm this command to continue.")

        let running = BackendCommandPresentation(
            response: try Self.response(state: "running", result: nil, version: 3)
        )
        XCTAssertFalse(running.isCancellable)
        XCTAssertFalse(running.isTerminal)
        XCTAssertNil(running.nextStepHint)

        let succeeded = BackendCommandPresentation(
            response: try Self.response(state: "succeeded", result: nil, version: 4)
        )
        XCTAssertFalse(succeeded.isCancellable)
        XCTAssertTrue(succeeded.isTerminal)
        XCTAssertNil(succeeded.nextStepHint)
    }

    func testHomeVoiceDockCopyMatchesLifecycleAndFollowUp() throws {
        let queued = BackendCommandPresentation(
            response: try Self.response(state: "queued", result: nil, version: 2)
        )
        let followUp = HomeVoiceDockCopy.make(
            voice: .listening,
            isFollowUpListen: true,
            targetLabel: nil,
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(followUp.title, "Don’t press")
        XCTAssertEqual(followUp.status, "Listening")
        XCTAssertEqual(followUp.action, "Say the name. Don’t hold the button.")
        XCTAssertEqual(followUp.accessibilityValue, "Listening")

        let ask = HomeVoiceDockCopy.make(
            voice: .clarificationRequired(.missingSendRecipient),
            isFollowUpListen: false,
            targetLabel: nil,
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(ask.status, "Say a name")
        XCTAssertTrue(ask.action.contains("Don’t press"))
        XCTAssertEqual(ask.accessibilityValue, "Needs clarification")

        let askBody = HomeVoiceDockCopy.make(
            voice: .clarificationRequired(.missingSendBody),
            isFollowUpListen: false,
            targetLabel: nil,
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(askBody.status, "Say the message")
        XCTAssertTrue(askBody.action.contains("What should I say?"))

        let bodyListen = HomeVoiceDockCopy.make(
            voice: .listening,
            isFollowUpListen: true,
            followUpListenIsBody: true,
            targetLabel: nil,
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(bodyListen.action, "Say the message. Don’t hold the button.")

        let sentQueued = HomeVoiceDockCopy.make(
            voice: .submitted("cmd_1"),
            isFollowUpListen: false,
            targetLabel: nil,
            presentation: queued,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(sentQueued.status, "Queued")
        XCTAssertEqual(sentQueued.action, "Queued. Cancel above, then speak again.")
        XCTAssertEqual(sentQueued.accessibilityValue, "Submitted")

        let needsConfirm = HomeVoiceDockCopy.make(
            voice: .submitted("cmd_1"),
            isFollowUpListen: false,
            targetLabel: nil,
            presentation: queued,
            isAwaitingConfirmation: true
        )
        XCTAssertEqual(needsConfirm.status, "Needs confirm")
        XCTAssertEqual(needsConfirm.action, "Confirm this command")

        let failed = BackendCommandPresentation(
            response: try Self.response(
                state: "failed",
                result: nil,
                presentation: Self.presentation(
                    displayText: "Command status: failed.",
                    terminal: true
                ),
                version: 3
            )
        )
        let leftoverWait = HomeVoiceDockCopy.make(
            voice: .submitted("cmd_1"),
            isFollowUpListen: false,
            targetLabel: nil,
            presentation: failed,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(leftoverWait.status, "Didn’t finish")
        XCTAssertEqual(leftoverWait.action, "Command status: failed.")
        XCTAssertNotEqual(leftoverWait.status, "Queued")
        XCTAssertNotEqual(leftoverWait.action, "Sent. Waiting for the next server update.")

        let succeeded = BackendCommandPresentation(
            response: try Self.response(state: "succeeded", result: nil, version: 4)
        )
        let done = HomeVoiceDockCopy.make(
            voice: .submitted("cmd_1"),
            isFollowUpListen: false,
            targetLabel: nil,
            presentation: succeeded,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(done.status, "Done")
        XCTAssertEqual(done.action, "Command status: succeeded.")

        let released = HomeVoiceDockCopy.make(
            voice: .submitted("cmd_1"),
            isFollowUpListen: false,
            targetLabel: nil,
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(released.status, "Push to talk")
        XCTAssertEqual(released.action, "Hold and speak a command")
        XCTAssertEqual(released.accessibilityValue, "Ready")

        let askAgent = HomeVoiceDockCopy.make(
            voice: .idle,
            isFollowUpListen: false,
            targetLabel: "apns-diagnostic",
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(askAgent.title, "Ask apns-diagnostic")
        XCTAssertEqual(askAgent.action, "Hold and speak to apns-diagnostic")

        let asked = HomeVoiceDockCopy.make(
            voice: .asked("apns-diagnostic"),
            isFollowUpListen: false,
            targetLabel: "apns-diagnostic",
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(asked.status, "Asked")
        XCTAssertEqual(asked.action, "Asked apns-diagnostic.")

        let selectAgent = HomeVoiceDockCopy.make(
            voice: .clarificationRequired(.selectAgent),
            isFollowUpListen: false,
            targetLabel: nil,
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(selectAgent.status, "Select an agent")
        XCTAssertEqual(selectAgent.action, "Select an agent first.")

        let notListening = HomeVoiceDockCopy.make(
            voice: .clarificationRequired(.agentNotListening),
            isFollowUpListen: false,
            targetLabel: "apns-diagnostic",
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(notListening.status, "Not listening")
        XCTAssertEqual(notListening.action, "apns-diagnostic is not listening.")
    }

    func testCommandLifecycleConflictsAreDetectedFrom409Copy() {
        let emptyMetadata = APIErrorMetadata(retryable: false, retryAfter: nil, requestID: nil)
        XCTAssertTrue(
            APIClientError.badStatus(
                409,
                "Command is not awaiting confirmation",
                emptyMetadata
            ).isAlreadyResolvedConfirmationConflict
        )
        XCTAssertTrue(
            APIClientError.badStatus(
                409,
                "The selected agent is not listening.",
                APIErrorMetadata(
                    retryable: false,
                    retryAfter: nil,
                    requestID: nil,
                    errorCode: "agent_not_listening"
                )
            ).isAgentNotListening
        )
        XCTAssertFalse(
            APIClientError.badStatus(
                409,
                "Command is not awaiting confirmation",
                emptyMetadata
            ).isAgentNotListening
        )
        XCTAssertTrue(
            APIClientError.badStatus(
                409,
                "Confirmation token was already used",
                emptyMetadata
            ).isAlreadyResolvedConfirmationConflict
        )
        XCTAssertFalse(
            APIClientError.badStatus(
                409,
                "Command is not awaiting confirmation",
                emptyMetadata
            ).isAlreadyResolvedCancelConflict
        )
        XCTAssertTrue(
            APIClientError.badStatus(
                409,
                "Command cannot be cancelled in its current state",
                emptyMetadata
            ).isAlreadyResolvedCancelConflict
        )
        XCTAssertTrue(
            APIClientError.badStatus(
                409,
                "Command changed before it could be cancelled",
                emptyMetadata
            ).isAlreadyResolvedCancelConflict
        )
        XCTAssertFalse(
            APIClientError.badStatus(
                409,
                "The command effect already started and must finish reconciliation before it can be undone",
                emptyMetadata
            ).isAlreadyResolvedCancelConflict
        )
        XCTAssertFalse(
            APIClientError.badStatus(
                409,
                "Some other conflict",
                emptyMetadata
            ).isAlreadyResolvedConfirmationConflict
        )
        XCTAssertFalse(
            APIClientError.badStatus(
                400,
                "Command is not awaiting confirmation",
                emptyMetadata
            ).isAlreadyResolvedConfirmationConflict
        )
    }

    func testMissingOrInvalidPresentationIsGenericAndSilent() throws {
        let missing = BackendCommandPresentation(
            response: try Self.response(
                state: "succeeded",
                result: .object([
                    "kind": .string("message"),
                    "delivery_state": .string("sent"),
                ])
            )
        )
        XCTAssertEqual(missing.message, "Command status: succeeded.")
        XCTAssertNil(missing.voiceScript)
        XCTAssertTrue(missing.isTerminal)
        XCTAssertFalse(missing.isServerValidated)

        // Presentation terminality cannot contradict the canonical state.
        let mismatched = BackendCommandPresentation(
            response: try Self.response(
                state: "succeeded",
                result: nil,
                presentation: Self.presentation(
                    displayText: "Do not trust this mismatch.",
                    voiceScript: "Do not speak this mismatch.",
                    terminal: false
                )
            )
        )
        XCTAssertEqual(mismatched.message, "Command status: succeeded.")
        XCTAssertNil(mismatched.voiceScript)
        XCTAssertTrue(mismatched.isTerminal)
        XCTAssertFalse(mismatched.isServerValidated)
    }

    func testPresentationValidationUsesOpenAPIBounds() {
        XCTAssertNotNil(Self.presentation(locale: String(repeating: "a", count: 32)).validated(for: "queued"))
        XCTAssertNil(Self.presentation(locale: String(repeating: "a", count: 33)).validated(for: "queued"))
        XCTAssertNotNil(Self.presentation(displayText: String(repeating: "d", count: 512)).validated(for: "queued"))
        XCTAssertNil(Self.presentation(displayText: String(repeating: "d", count: 513)).validated(for: "queued"))
        XCTAssertNotNil(Self.presentation(voiceScript: String(repeating: "v", count: 512)).validated(for: "queued"))
        XCTAssertNil(Self.presentation(voiceScript: String(repeating: "v", count: 513)).validated(for: "queued"))
    }

    func testScopeUsesStableOwnerAndCanonicalEffectivePortOrigin() throws {
        let scope = try XCTUnwrap(ActiveCommandScope(
            backendURL: URL(string: "HTTPS://API.Example.COM/path/to/v1?query=ignored#fragment"),
            ownerUserID: "usr_stable"
        ))
        XCTAssertEqual(scope.backendOrigin, "https://api.example.com:443")
        XCTAssertEqual(scope.ownerUserID, "usr_stable")

        let customPort = try XCTUnwrap(ActiveCommandScope(
            backendURL: URL(string: "http://api.example.com:8787/anything"),
            ownerUserID: "usr_stable"
        ))
        XCTAssertEqual(customPort.backendOrigin, "http://api.example.com:8787")
    }

    func testRestoreClearsCheckpointOutsideOwnerOrOriginScope() throws {
        let mismatchedScopes = [
            ActiveCommandScope(
                backendURL: URL(string: "https://api.example.com"),
                ownerUserID: "usr_other"
            ),
            ActiveCommandScope(
                backendURL: URL(string: "https://other.example.com"),
                ownerUserID: "usr_stable"
            ),
        ]
        for mismatch in mismatchedScopes {
            let url = Self.temporarySQLiteURL("scope")
            defer { Self.removeSQLiteArtifacts(at: url) }
            let store = SQLiteStore(databaseURL: url)
            XCTAssertTrue(store.saveActiveCommandCheckpoint(Self.checkpoint(
                phase: .acknowledged,
                commandID: "cmd_scoped",
                state: "running",
                version: 3
            )))
            let coordinator = ActiveCommandCheckpointCoordinator(
                store: store,
                synthesizer: RecordingVoiceSynthesizer()
            )

            XCTAssertNil(try coordinator.restore(scope: try XCTUnwrap(mismatch)))
            XCTAssertNil(store.loadActiveCommandCheckpoint())
        }
    }

    func testReducerOnlyTreatsIdenticalEqualVersionSnapshotAsIdempotent() throws {
        let current = Self.checkpoint(
            phase: .acknowledged,
            commandID: "cmd_current",
            state: "running",
            version: 8
        )

        XCTAssertEqual(
            ActiveCommandCheckpointReducer.apply(
                response: try Self.response(commandID: "cmd_old", state: "succeeded", result: nil, version: 9),
                expectedCommandID: "cmd_old",
                current: current
            ),
            .rejected(.staleExpectedCommand)
        )
        XCTAssertEqual(
            ActiveCommandCheckpointReducer.apply(
                response: try Self.response(commandID: "cmd_wrong", state: "running", result: nil, version: 9),
                expectedCommandID: "cmd_current",
                current: current
            ),
            .rejected(.responseCommandMismatch)
        )
        XCTAssertEqual(
            ActiveCommandCheckpointReducer.apply(
                response: try Self.response(commandID: "cmd_current", state: "queued", result: nil, version: 7),
                expectedCommandID: "cmd_current",
                current: current
            ),
            .rejected(.lowerVersion)
        )
        XCTAssertEqual(
            ActiveCommandCheckpointReducer.apply(
                response: try Self.response(commandID: "cmd_current", state: "running", result: nil, version: 8),
                expectedCommandID: "cmd_current",
                current: current
            ),
            .idempotent
        )
        XCTAssertEqual(
            ActiveCommandCheckpointReducer.apply(
                response: try Self.response(commandID: "cmd_current", state: "failed", result: nil, version: 8),
                expectedCommandID: "cmd_current",
                current: current
            ),
            .rejected(.divergentEqualVersion)
        )
        XCTAssertEqual(
            ActiveCommandCheckpointReducer.apply(
                response: try Self.response(
                    commandID: "cmd_current",
                    state: "running",
                    result: nil,
                    presentation: Self.presentation(
                        displayText: "A divergent same-version snapshot.",
                        terminal: false
                    ),
                    version: 8
                ),
                expectedCommandID: "cmd_current",
                current: current
            ),
            .rejected(.divergentEqualVersion)
        )
    }

    func testOldNotFoundCannotClearOrReplayNewerCommand() throws {
        let envelope = try Self.envelope(commandID: "cmd_new")
        let current = ActiveCommandCheckpoint(
            phase: .submitting,
            commandID: envelope.commandID,
            backendState: nil,
            backendVersion: nil,
            envelope: envelope,
            validatedPresentation: nil,
            lastAnnouncedVersion: nil,
            backendOrigin: "https://api.example.com:443",
            ownerUserID: "usr_stable",
            createdAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            ActiveCommandCheckpointReducer.handleNotFound(
                expectedCommandID: "cmd_old",
                current: current
            ),
            .stale
        )
        XCTAssertEqual(current.commandID, "cmd_new")
        XCTAssertEqual(current.envelope, envelope)
    }

    func testSecondNonterminalSubmitIsRejected() throws {
        let current = Self.checkpoint(
            phase: .acknowledged,
            commandID: "cmd_active",
            state: "running",
            version: 2
        )
        XCTAssertThrowsError(
            try ActiveCommandCheckpointReducer.start(
                current: current,
                envelope: Self.envelope(commandID: "cmd_second"),
                scope: try XCTUnwrap(ActiveCommandScope(
                    backendURL: URL(string: "https://api.example.com/path?ignored=1"),
                    ownerUserID: "usr_stable"
                )),
                createdAt: Date(timeIntervalSince1970: 200)
            )
        ) { error in
            XCTAssertEqual(error as? ActiveCommandCheckpointError, .commandInProgress("cmd_active"))
        }
    }

    func testConfirmSnapshotKeepsDisabledFailureInsteadOfLaggingQueuedGet() throws {
        let confirm = try Self.response(
            commandID: "cmd_send",
            state: "failed",
            result: nil,
            presentation: Self.presentation(
                displayText: "The backend could not complete this command.",
                terminal: true
            ),
            version: 4
        )
        let queuedGet = try Self.response(
            commandID: "cmd_send",
            state: "queued",
            result: nil,
            version: 3
        )
        let chosen = CommandLifecycle.snapshotAfterConfirm(confirm: confirm, get: queuedGet)
        XCTAssertEqual(chosen.state, "failed")
        XCTAssertNotEqual(chosen.state, "queued")
        XCTAssertEqual(chosen.version, 4)

        let failedGet = try Self.response(
            commandID: "cmd_send",
            state: "failed",
            result: nil,
            presentation: Self.presentation(
                displayText: "The backend could not complete this command.",
                terminal: true
            ),
            version: 5
        )
        let queuedConfirm = try Self.response(
            commandID: "cmd_send",
            state: "queued",
            result: nil,
            version: 3
        )
        let drainedGet = CommandLifecycle.snapshotAfterConfirm(
            confirm: queuedConfirm,
            get: failedGet
        )
        XCTAssertEqual(drainedGet.state, "failed")
        XCTAssertEqual(drainedGet.version, 5)

        let newerQueuedGet = try Self.response(
            commandID: "cmd_send",
            state: "queued",
            result: nil,
            version: 5
        )
        let failedOverNewerQueued = CommandLifecycle.snapshotAfterConfirm(
            confirm: confirm,
            get: newerQueuedGet
        )
        XCTAssertEqual(failedOverNewerQueued.state, "failed")
        XCTAssertNotEqual(failedOverNewerQueued.state, "queued")
        XCTAssertEqual(failedOverNewerQueued.version, 4)

        let cancelled = try Self.response(
            commandID: "cmd_send",
            state: "cancelled",
            result: nil,
            presentation: Self.presentation(
                displayText: "The command was cancelled.",
                terminal: true
            ),
            version: 4
        )
        let cancelKeepsTerminal = CommandLifecycle.snapshotAfterConfirm(
            confirm: cancelled,
            get: newerQueuedGet
        )
        XCTAssertEqual(cancelKeepsTerminal.state, "cancelled")
        XCTAssertNotEqual(cancelKeepsTerminal.state, "queued")
    }

    func testDisabledSendConfirmFailedReleasesNextSpeakFence() throws {
        let current = Self.checkpoint(
            phase: .acknowledged,
            commandID: "cmd_send",
            state: "awaiting_confirmation",
            version: 2
        )
        let failed = try Self.response(
            commandID: "cmd_send",
            state: "failed",
            result: nil,
            presentation: Self.presentation(
                displayText: "The backend could not complete this command.",
                terminal: true
            ),
            version: 4
        )
        guard case let .replace(next) = ActiveCommandCheckpointReducer.apply(
            response: failed,
            expectedCommandID: "cmd_send",
            current: current
        ) else {
            return XCTFail("disabled send_message confirm must replace awaiting_confirmation")
        }
        XCTAssertEqual(next.backendState, "failed")
        XCTAssertNotEqual(next.backendState, "queued")
        XCTAssertEqual(next.phase, .terminalPendingPresentation)

        let presentation = try XCTUnwrap(BackendCommandPresentation(checkpoint: next))
        XCTAssertTrue(presentation.isTerminal)
        XCTAssertFalse(presentation.isCancellable)
        let dock = HomeVoiceDockCopy.make(
            voice: .submitted("cmd_send"),
            isFollowUpListen: false,
            targetLabel: nil,
            presentation: presentation,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(dock.status, "Didn’t finish")
        XCTAssertNotEqual(dock.status, "Queued")

        XCTAssertNoThrow(
            try ActiveCommandCheckpointReducer.start(
                current: next,
                envelope: Self.envelope(commandID: "cmd_next"),
                scope: try XCTUnwrap(ActiveCommandScope(
                    backendURL: URL(string: "https://api.example.com"),
                    ownerUserID: "usr_stable"
                )),
                createdAt: Date(timeIntervalSince1970: 400)
            )
        )
    }

    func testJournalIsDurableBeforePost() async throws {
        let url = Self.temporarySQLiteURL("write-before-post")
        defer { Self.removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        let coordinator = ActiveCommandCheckpointCoordinator(
            store: store,
            synthesizer: RecordingVoiceSynthesizer()
        )
        let envelope = try Self.envelope(commandID: "cmd_journaled")
        let scope = try XCTUnwrap(ActiveCommandScope(
            backendURL: URL(string: "https://api.example.com/v1?ignored=1"),
            ownerUserID: "usr_stable"
        ))

        _ = try await coordinator.submit(
            envelope: envelope,
            scope: scope,
            createdAt: Date(timeIntervalSince1970: 300)
        ) { postedEnvelope in
            let journaled = try XCTUnwrap(store.loadActiveCommandCheckpoint())
            XCTAssertEqual(journaled.phase, .submitting)
            XCTAssertEqual(journaled.envelope, envelope)
            XCTAssertEqual(postedEnvelope, envelope)
            return try Self.response(
                commandID: envelope.commandID,
                state: "queued",
                result: nil,
                version: 1
            )
        }

        let acknowledged = try XCTUnwrap(store.loadActiveCommandCheckpoint())
        XCTAssertEqual(acknowledged.phase, .acknowledged)
        XCTAssertNil(acknowledged.envelope)
    }

    func testUncertainSubmitFailureKeepsGenericPendingCheckpointForRecovery() async throws {
        let url = Self.temporarySQLiteURL("uncertain-submit")
        defer { Self.removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        let coordinator = ActiveCommandCheckpointCoordinator(
            store: store,
            synthesizer: RecordingVoiceSynthesizer()
        )
        let envelope = try Self.envelope(commandID: "cmd_uncertain")
        var beganPresentation: BackendCommandPresentation?

        do {
            _ = try await coordinator.submit(
                envelope: envelope,
                scope: try XCTUnwrap(ActiveCommandScope(
                    backendURL: URL(string: "https://api.example.com"),
                    ownerUserID: "usr_stable"
                )),
                onBegan: { beganPresentation = coordinator.presentation }
            ) { _ in
                throw APIClientError.network("connection lost after upload")
            }
            XCTFail("Expected the uncertain POST to fail")
        } catch let error as APIClientError {
            guard case .network = error else {
                return XCTFail("Expected a network error")
            }
        }

        XCTAssertEqual(beganPresentation?.state, "submitting")
        XCTAssertEqual(
            beganPresentation?.message,
            "Sending command. Waiting for the backend to confirm receipt."
        )
        XCTAssertNil(beganPresentation?.voiceScript)
        XCTAssertEqual(store.loadActiveCommandCheckpoint()?.envelope, envelope)
        XCTAssertEqual(coordinator.commandIDForReconciliation, envelope.commandID)
    }

    func testDefinitelyRejectedSubmitCanReleaseFenceWithoutClearingAcknowledgedCommand() throws {
        let url = Self.temporarySQLiteURL("rejected-submit")
        defer { Self.removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        let coordinator = ActiveCommandCheckpointCoordinator(
            store: store,
            synthesizer: RecordingVoiceSynthesizer()
        )
        let scope = try XCTUnwrap(ActiveCommandScope(
            backendURL: URL(string: "https://api.example.com"),
            ownerUserID: "usr_stable"
        ))

        try coordinator.begin(
            envelope: Self.envelope(commandID: "cmd_rejected"),
            scope: scope
        )
        try coordinator.abandonUnacknowledgedSubmission(expectedCommandID: "cmd_rejected")
        XCTAssertNil(coordinator.checkpoint)
        XCTAssertNil(coordinator.presentation)
        XCTAssertNil(store.loadActiveCommandCheckpoint())

        try coordinator.begin(
            envelope: Self.envelope(commandID: "cmd_next"),
            scope: scope
        )
        _ = try coordinator.accept(
            response: Self.response(
                commandID: "cmd_next",
                state: "queued",
                result: nil,
                version: 1
            ),
            expectedCommandID: "cmd_next"
        )
        try coordinator.abandonUnacknowledgedSubmission(expectedCommandID: "cmd_next")
        XCTAssertEqual(coordinator.checkpoint?.commandID, "cmd_next")
        XCTAssertEqual(coordinator.checkpoint?.phase, .acknowledged)
    }

    func testAllowlistedPrePersistenceErrorsAreDefinitelyRejected() {
        XCTAssertTrue(AppStore.commandSubmissionDefinitelyRejected(APIClientError.noToken))
        XCTAssertTrue(AppStore.commandSubmissionDefinitelyRejected(APIClientError.invalidBaseURL))

        for (status, errorCode) in [
            (400, "validation_error"),
            (401, "unauthorized"),
            (404, "not_found"),
            (422, "unsupported_intent"),
        ] {
            XCTAssertTrue(AppStore.commandSubmissionDefinitelyRejected(APIClientError.badStatus(
                status,
                "rejected before persistence",
                APIErrorMetadata(
                    retryable: false,
                    retryAfter: nil,
                    requestID: nil,
                    errorCode: errorCode
                )
            )))
        }
    }

    func testUnknownNonRetryable4xxIsAmbiguous() {
        XCTAssertFalse(AppStore.commandSubmissionDefinitelyRejected(APIClientError.badStatus(
            422,
            "unknown client error",
            APIErrorMetadata(
                retryable: false,
                retryAfter: nil,
                requestID: nil,
                errorCode: "future_contract_error"
            )
        )))
        XCTAssertFalse(AppStore.commandSubmissionDefinitelyRejected(APIClientError.badStatus(
            422,
            "missing structured code",
            APIErrorMetadata(retryable: false, retryAfter: nil, requestID: nil)
        )))
        XCTAssertFalse(AppStore.commandSubmissionDefinitelyRejected(APIClientError.badStatus(
            422,
            "status and code do not match",
            APIErrorMetadata(
                retryable: false,
                retryAfter: nil,
                requestID: nil,
                errorCode: "validation_error"
            )
        )))

        XCTAssertFalse(AppStore.commandSubmissionDefinitelyRejected(APIClientError.network("timeout")))
        XCTAssertFalse(AppStore.commandSubmissionDefinitelyRejected(APIClientError.decoding))
        for code in [408, 409, 425, 429, 500] {
            XCTAssertFalse(AppStore.commandSubmissionDefinitelyRejected(APIClientError.badStatus(
                code,
                "ambiguous",
                APIErrorMetadata(retryable: code >= 500, retryAfter: nil, requestID: nil)
            )))
        }
    }

    func testAPIClientPreservesBackendErrorCodeInMetadata() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIErrorURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            APIErrorURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        APIErrorURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.example.com")!,
                statusCode: 422,
                httpVersion: nil,
                headerFields: nil
            ))
            let body = Data(#"{"error":{"code":"unsupported_intent","message":"unsupported","retryable":false,"request_id":"req_code"}}"#.utf8)
            return (response, body)
        }
        let previousBaseURL = UserDefaults.standard.string(forKey: "vab.apiBase")
        defer {
            if let previousBaseURL {
                UserDefaults.standard.set(previousBaseURL, forKey: "vab.apiBase")
            } else {
                UserDefaults.standard.removeObject(forKey: "vab.apiBase")
            }
        }
        let client = APIClient(session: session)
        client.baseURL = URL(string: "https://api.example.com")
        client.token = "test-token"

        do {
            _ = try await client.createCommand(Self.envelope(commandID: "cmd_error_code"))
            XCTFail("Expected the backend rejection")
        } catch let APIClientError.badStatus(status, _, metadata) {
            XCTAssertEqual(status, 422)
            XCTAssertEqual(metadata.errorCode, "unsupported_intent")
            XCTAssertEqual(metadata.requestID, "req_code")
            XCTAssertFalse(metadata.retryable)
        } catch {
            XCTFail("Expected structured API status error, got \(error)")
        }
    }

    func testAPIClientGETBypassesURLCache() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIErrorURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            APIErrorURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        APIErrorURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data(#"{"sessions":[]}"#.utf8))
        }
        let previousBaseURL = UserDefaults.standard.string(forKey: "vab.apiBase")
        defer {
            if let previousBaseURL {
                UserDefaults.standard.set(previousBaseURL, forKey: "vab.apiBase")
            } else {
                UserDefaults.standard.removeObject(forKey: "vab.apiBase")
            }
        }
        let client = APIClient(session: session)
        client.baseURL = URL(string: "https://api.example.com")
        client.token = "test-token"

        let page = try await client.listSessionsPage()
        XCTAssertTrue(page.sessions.isEmpty)
    }

    func testPersistenceFailurePreventsPost() async throws {
        let parentFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-knock-parent-file-\(UUID().uuidString)")
        try Data("not-a-directory".utf8).write(to: parentFile)
        defer { try? FileManager.default.removeItem(at: parentFile) }
        let store = SQLiteStore(databaseURL: parentFile.appendingPathComponent("db.sqlite"))
        XCTAssertFalse(store.isAvailable)
        let coordinator = ActiveCommandCheckpointCoordinator(
            store: store,
            synthesizer: RecordingVoiceSynthesizer()
        )
        var postCount = 0

        do {
            _ = try await coordinator.submit(
                envelope: Self.envelope(commandID: "cmd_not_sent"),
                scope: try XCTUnwrap(ActiveCommandScope(
                    backendURL: URL(string: "https://api.example.com"),
                    ownerUserID: "usr_stable"
                ))
            ) { _ in
                postCount += 1
                return try Self.response(state: "queued", result: nil)
            }
            XCTFail("Expected the unavailable journal to fail closed")
        } catch {
            XCTAssertEqual(error as? ActiveCommandCheckpointError, .persistenceFailed)
        }
        XCTAssertEqual(postCount, 0)
    }

    func testColdStartSubmitting404ReplaysExactEnvelope() async throws {
        let url = Self.temporarySQLiteURL("replay")
        defer { Self.removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        let scope = try XCTUnwrap(ActiveCommandScope(
            backendURL: URL(string: "https://api.example.com/some/path"),
            ownerUserID: "usr_stable"
        ))
        let envelope = try Self.envelope(commandID: "cmd_replay", idempotencyKey: "idem_exact")
        let first = ActiveCommandCheckpointCoordinator(
            store: store,
            synthesizer: RecordingVoiceSynthesizer()
        )
        try first.begin(
            envelope: envelope,
            scope: scope,
            createdAt: Date(timeIntervalSince1970: 400)
        )

        let reopened = ActiveCommandCheckpointCoordinator(
            store: SQLiteStore(databaseURL: url),
            synthesizer: RecordingVoiceSynthesizer()
        )
        let restoredPending = try XCTUnwrap(reopened.restore(scope: scope))
        XCTAssertEqual(restoredPending.state, "submitting")
        XCTAssertNil(restoredPending.voiceScript)
        var replayedEnvelope: CommandEnvelope?
        let application = try await reopened.reconcileCurrent(
            get: { _ in
                throw APIClientError.badStatus(
                    404,
                    "missing",
                    APIErrorMetadata(retryable: false, retryAfter: nil, requestID: nil)
                )
            },
            replay: { replay in
                replayedEnvelope = replay
                return try Self.response(
                    commandID: replay.commandID,
                    state: "queued",
                    result: nil,
                    version: 1
                )
            }
        )

        XCTAssertEqual(application?.outcome, .applied)
        XCTAssertEqual(replayedEnvelope, envelope)
        XCTAssertEqual(replayedEnvelope?.idempotencyKey, "idem_exact")
        XCTAssertNil(reopened.checkpoint?.envelope)
    }

    func testColdStartReplayDefiniteRejectionClearsSubmittingFenceAndAllowsNextCommand() async throws {
        let url = Self.temporarySQLiteURL("replay-definite-rejection")
        defer { Self.removeSQLiteArtifacts(at: url) }
        let scope = try XCTUnwrap(ActiveCommandScope(
            backendURL: URL(string: "https://api.example.com"),
            ownerUserID: "usr_stable"
        ))
        let first = ActiveCommandCheckpointCoordinator(
            store: SQLiteStore(databaseURL: url),
            synthesizer: RecordingVoiceSynthesizer()
        )
        try first.begin(
            envelope: Self.envelope(commandID: "cmd_replay_rejected"),
            scope: scope
        )

        let reopenedStore = SQLiteStore(databaseURL: url)
        let reopened = ActiveCommandCheckpointCoordinator(
            store: reopenedStore,
            synthesizer: RecordingVoiceSynthesizer()
        )
        _ = try XCTUnwrap(reopened.restore(scope: scope))
        let application = try await reopened.reconcileCurrent(
            get: { _ in
                throw APIClientError.badStatus(
                    404,
                    "missing",
                    APIErrorMetadata(
                        retryable: false,
                        retryAfter: nil,
                        requestID: nil,
                        errorCode: "not_found"
                    )
                )
            },
            replay: { _ in
                throw APIClientError.badStatus(
                    400,
                    "invalid envelope",
                    APIErrorMetadata(
                        retryable: false,
                        retryAfter: nil,
                        requestID: nil,
                        errorCode: "validation_error"
                    )
                )
            },
            definitelyRejected: { AppStore.commandSubmissionDefinitelyRejected($0) }
        )

        XCTAssertNil(application)
        XCTAssertNil(reopened.checkpoint)
        XCTAssertNil(reopened.presentation)
        XCTAssertNil(reopenedStore.loadActiveCommandCheckpoint())

        try reopened.begin(
            envelope: Self.envelope(commandID: "cmd_after_rejection"),
            scope: scope
        )
        XCTAssertEqual(reopened.checkpoint?.commandID, "cmd_after_rejection")
    }

    func testColdStartReplayAmbiguousConflictRetainsSubmittingFence() async throws {
        let url = Self.temporarySQLiteURL("replay-ambiguous-conflict")
        defer { Self.removeSQLiteArtifacts(at: url) }
        let scope = try XCTUnwrap(ActiveCommandScope(
            backendURL: URL(string: "https://api.example.com"),
            ownerUserID: "usr_stable"
        ))
        let envelope = try Self.envelope(commandID: "cmd_replay_ambiguous")
        let first = ActiveCommandCheckpointCoordinator(
            store: SQLiteStore(databaseURL: url),
            synthesizer: RecordingVoiceSynthesizer()
        )
        try first.begin(envelope: envelope, scope: scope)

        let reopenedStore = SQLiteStore(databaseURL: url)
        let reopened = ActiveCommandCheckpointCoordinator(
            store: reopenedStore,
            synthesizer: RecordingVoiceSynthesizer()
        )
        _ = try XCTUnwrap(reopened.restore(scope: scope))

        do {
            _ = try await reopened.reconcileCurrent(
                get: { _ in
                    throw APIClientError.badStatus(
                        404,
                        "missing",
                        APIErrorMetadata(
                            retryable: false,
                            retryAfter: nil,
                            requestID: nil,
                            errorCode: "not_found"
                        )
                    )
                },
                replay: { _ in
                    throw APIClientError.badStatus(
                        409,
                        "conflict",
                        APIErrorMetadata(
                            retryable: false,
                            retryAfter: nil,
                            requestID: nil,
                            errorCode: "conflict"
                        )
                    )
                },
                definitelyRejected: { AppStore.commandSubmissionDefinitelyRejected($0) }
            )
            XCTFail("Expected the ambiguous replay error")
        } catch let APIClientError.badStatus(status, _, _) {
            XCTAssertEqual(status, 409)
        }

        XCTAssertEqual(reopened.checkpoint?.envelope, envelope)
        XCTAssertEqual(reopenedStore.loadActiveCommandCheckpoint()?.envelope, envelope)
        XCTAssertThrowsError(try reopened.begin(
            envelope: Self.envelope(commandID: "cmd_blocked_by_ambiguity"),
            scope: scope
        )) { error in
            XCTAssertEqual(
                error as? ActiveCommandCheckpointError,
                .commandInProgress("cmd_replay_ambiguous")
            )
        }
    }

    func testColdStartAwaitingConfirmationRotatesAndDurablyStoresFreshToken() async throws {
        let url = Self.temporarySQLiteURL("confirmation-replay")
        defer { Self.removeSQLiteArtifacts(at: url) }
        let scope = try XCTUnwrap(ActiveCommandScope(
            backendURL: URL(string: "https://api.example.com/v1"),
            ownerUserID: "usr_stable"
        ))
        let envelope = try Self.envelope(
            commandID: "cmd_confirmation_replay",
            idempotencyKey: "idem_confirmation_exact"
        )
        let first = ActiveCommandCheckpointCoordinator(
            store: SQLiteStore(databaseURL: url),
            synthesizer: RecordingVoiceSynthesizer()
        )
        try first.begin(envelope: envelope, scope: scope)

        let reopened = ActiveCommandCheckpointCoordinator(
            store: SQLiteStore(databaseURL: url),
            synthesizer: RecordingVoiceSynthesizer()
        )
        let restoredPending = try XCTUnwrap(reopened.restore(scope: scope))
        XCTAssertEqual(restoredPending.state, "submitting")
        XCTAssertNil(restoredPending.voiceScript)
        var replayedEnvelope: CommandEnvelope?
        let application = try await reopened.reconcileCurrent(
            get: { commandID in
                try Self.response(
                    commandID: commandID,
                    state: "awaiting_confirmation",
                    result: nil,
                    version: 2
                )
            },
            replay: { replay in
                replayedEnvelope = replay
                return try Self.response(
                    commandID: replay.commandID,
                    state: "awaiting_confirmation",
                    result: nil,
                    confirmationToken: "fresh-one-time-token",
                    version: 2
                )
            }
        )

        XCTAssertEqual(application?.outcome, .applied)
        XCTAssertEqual(replayedEnvelope, envelope)
        XCTAssertEqual(replayedEnvelope?.idempotencyKey, "idem_confirmation_exact")
        XCTAssertEqual(reopened.durablePendingConfirmation?.confirmation_token, "fresh-one-time-token")
        XCTAssertNil(reopened.checkpoint?.envelope)

        let secondReopen = ActiveCommandCheckpointCoordinator(
            store: SQLiteStore(databaseURL: url),
            synthesizer: RecordingVoiceSynthesizer()
        )
        _ = try secondReopen.restore(scope: scope)
        XCTAssertEqual(
            secondReopen.durablePendingConfirmation?.confirmation_token,
            "fresh-one-time-token"
        )
    }

    func testInitialConfirmationTokenIsJournaledBeforeAppConsumption() async throws {
        let url = Self.temporarySQLiteURL("confirmation-journal")
        defer { Self.removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        let coordinator = ActiveCommandCheckpointCoordinator(
            store: store,
            synthesizer: RecordingVoiceSynthesizer()
        )
        let envelope = try Self.envelope(commandID: "cmd_confirmation_journal")

        _ = try await coordinator.submit(
            envelope: envelope,
            scope: try XCTUnwrap(ActiveCommandScope(
                backendURL: URL(string: "https://api.example.com"),
                ownerUserID: "usr_stable"
            ))
        ) { posted in
            try Self.response(
                commandID: posted.commandID,
                state: "awaiting_confirmation",
                result: nil,
                confirmationToken: "durable-one-time-token",
                version: 2
            )
        }

        XCTAssertEqual(
            store.loadActiveCommandCheckpoint()?.pendingConfirmation?.confirmation_token,
            "durable-one-time-token"
        )
    }

    func testNewerAwaitingConfirmationWithoutTokenInvalidatesOlderAuthority() throws {
        let oldConfirmation = PendingCommandConfirmation(
            command_id: "cmd_confirmation_race",
            confirmation_token: "stale-one-time-token",
            title: "Send message",
            risk: "high",
            confirm_required: true,
            reversible: false
        )
        let current = ActiveCommandCheckpoint(
            phase: .acknowledged,
            commandID: "cmd_confirmation_race",
            backendState: "awaiting_confirmation",
            backendVersion: 8,
            envelope: nil,
            validatedPresentation: nil,
            pendingConfirmation: oldConfirmation,
            lastAnnouncedVersion: nil,
            backendOrigin: "https://api.example.com:443",
            ownerUserID: "usr_stable",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let newerWithoutToken = try Self.response(
            commandID: "cmd_confirmation_race",
            state: "awaiting_confirmation",
            result: nil,
            version: 9
        )

        guard case let .replace(next) = ActiveCommandCheckpointReducer.apply(
            response: newerWithoutToken,
            expectedCommandID: "cmd_confirmation_race",
            current: current
        ) else {
            return XCTFail("Expected the newer backend version to replace the checkpoint")
        }
        XCTAssertNil(next.pendingConfirmation)
        XCTAssertEqual(next.backendVersion, 9)
    }

    func testSameVersionGetWithoutTokenKeepsJournaledConfirmation() throws {
        let confirmation = PendingCommandConfirmation(
            command_id: "cmd_confirmation_get",
            confirmation_token: "durable-one-time-token",
            title: "Send message",
            risk: "high",
            confirm_required: true,
            reversible: false
        )
        let current = ActiveCommandCheckpoint(
            phase: .acknowledged,
            commandID: "cmd_confirmation_get",
            backendState: "awaiting_confirmation",
            backendVersion: 2,
            envelope: nil,
            validatedPresentation: nil,
            pendingConfirmation: confirmation,
            lastAnnouncedVersion: nil,
            backendOrigin: "https://api.example.com:443",
            ownerUserID: "usr_stable",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let getWithoutToken = try Self.response(
            commandID: "cmd_confirmation_get",
            state: "awaiting_confirmation",
            result: nil,
            version: 2
        )

        XCTAssertEqual(
            ActiveCommandCheckpointReducer.apply(
                response: getWithoutToken,
                expectedCommandID: "cmd_confirmation_get",
                current: current
            ),
            .idempotent
        )
    }

    func testColdStartTerminalPresentationAndBackendTTSAreExactlyOncePerVersion() throws {
        let url = Self.temporarySQLiteURL("terminal")
        defer { Self.removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        let scope = try XCTUnwrap(ActiveCommandScope(
            backendURL: URL(string: "https://api.example.com/ignored"),
            ownerUserID: "usr_stable"
        ))
        let terminal = Self.checkpoint(
            phase: .terminalPendingPresentation,
            commandID: "cmd_terminal",
            state: "succeeded",
            version: 7,
            presentation: Self.presentation(
                displayText: "The server completed the command.",
                voiceScript: "Command complete.",
                terminal: true
            )
        )
        XCTAssertTrue(store.saveActiveCommandCheckpoint(terminal))

        let firstSynthesizer = RecordingVoiceSynthesizer()
        let first = ActiveCommandCheckpointCoordinator(store: store, synthesizer: firstSynthesizer)
        let restored = try XCTUnwrap(first.restore(scope: scope))
        XCTAssertEqual(restored.message, "The server completed the command.")
        XCTAssertEqual(firstSynthesizer.spoken, ["Command complete."])
        XCTAssertEqual(firstSynthesizer.stopCount, 1)
        XCTAssertEqual(store.loadActiveCommandCheckpoint()?.lastAnnouncedVersion, 7)

        let versionEight = try Self.response(
            commandID: "cmd_terminal",
            state: "succeeded",
            result: nil,
            presentation: Self.presentation(
                displayText: "The terminal state was updated.",
                voiceScript: "Command update complete.",
                terminal: true
            ),
            version: 8
        )
        XCTAssertEqual(
            try first.accept(response: versionEight, expectedCommandID: "cmd_terminal")?.outcome,
            .applied
        )
        XCTAssertEqual(
            try first.accept(response: versionEight, expectedCommandID: "cmd_terminal")?.outcome,
            .idempotent
        )
        XCTAssertEqual(firstSynthesizer.spoken, ["Command complete.", "Command update complete."])
        XCTAssertEqual(firstSynthesizer.stopCount, 2)
        XCTAssertEqual(store.loadActiveCommandCheckpoint()?.lastAnnouncedVersion, 8)

        let secondSynthesizer = RecordingVoiceSynthesizer()
        let reopened = ActiveCommandCheckpointCoordinator(
            store: SQLiteStore(databaseURL: url),
            synthesizer: secondSynthesizer
        )
        let reopenedPresentation = try XCTUnwrap(reopened.restore(scope: scope))
        XCTAssertEqual(reopenedPresentation.version, 8)
        XCTAssertEqual(reopenedPresentation.message, "The terminal state was updated.")
        XCTAssertTrue(secondSynthesizer.spoken.isEmpty)
        XCTAssertEqual(secondSynthesizer.stopCount, 0)

        try reopened.markPresented(commandID: "cmd_terminal", version: 8)
        XCTAssertNil(store.loadActiveCommandCheckpoint())
    }

    func testAnnouncementVersionIsRecordedOnlyAfterSynthesisFinishes() throws {
        let url = Self.temporarySQLiteURL("speech-completion")
        defer { Self.removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        let scope = try XCTUnwrap(ActiveCommandScope(
            backendURL: URL(string: "https://api.example.com"),
            ownerUserID: "usr_stable"
        ))
        XCTAssertTrue(store.saveActiveCommandCheckpoint(Self.checkpoint(
            phase: .terminalPendingPresentation,
            commandID: "cmd_speech_completion",
            state: "succeeded",
            version: 10,
            presentation: Self.presentation(
                displayText: "The command completed.",
                voiceScript: "Completion must be observed.",
                terminal: true
            )
        )))

        let synthesizer = RecordingVoiceSynthesizer(automaticallyCompletes: false)
        let coordinator = ActiveCommandCheckpointCoordinator(
            store: store,
            synthesizer: synthesizer
        )
        _ = try XCTUnwrap(coordinator.restore(scope: scope))
        try coordinator.announceDeferredIfNeeded()

        XCTAssertEqual(synthesizer.spoken, ["Completion must be observed."])
        XCTAssertEqual(synthesizer.pendingCompletionCount, 1)
        XCTAssertNil(store.loadActiveCommandCheckpoint()?.lastAnnouncedVersion)
        XCTAssertNil(coordinator.lastSpoken)

        synthesizer.finishNext()
        try coordinator.announceDeferredIfNeeded()

        XCTAssertEqual(synthesizer.spoken, ["Completion must be observed."])
        XCTAssertEqual(store.loadActiveCommandCheckpoint()?.lastAnnouncedVersion, 10)
        XCTAssertEqual(coordinator.lastSpoken, "Completion must be observed.")
    }

    func testCancelledAnnouncementRemainsPendingAndReplaysExactlyOnce() throws {
        let url = Self.temporarySQLiteURL("speech-cancellation")
        defer { Self.removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        let scope = try XCTUnwrap(ActiveCommandScope(
            backendURL: URL(string: "https://api.example.com"),
            ownerUserID: "usr_stable"
        ))
        XCTAssertTrue(store.saveActiveCommandCheckpoint(Self.checkpoint(
            phase: .terminalPendingPresentation,
            commandID: "cmd_speech_cancellation",
            state: "succeeded",
            version: 11,
            presentation: Self.presentation(
                displayText: "The command completed.",
                voiceScript: "Replay after interruption.",
                terminal: true
            )
        )))

        let synthesizer = RecordingVoiceSynthesizer(automaticallyCompletes: false)
        let coordinator = ActiveCommandCheckpointCoordinator(
            store: store,
            synthesizer: synthesizer
        )
        _ = try XCTUnwrap(coordinator.restore(scope: scope))
        try coordinator.markPresented(commandID: "cmd_speech_cancellation", version: 11)

        synthesizer.stop()

        XCTAssertNil(store.loadActiveCommandCheckpoint()?.lastAnnouncedVersion)
        XCTAssertEqual(store.loadActiveCommandCheckpoint()?.lastPresentedVersion, 11)
        XCTAssertNil(coordinator.lastSpoken)

        try coordinator.announceDeferredIfNeeded()
        try coordinator.announceDeferredIfNeeded()
        XCTAssertEqual(
            synthesizer.spoken,
            ["Replay after interruption.", "Replay after interruption."]
        )
        XCTAssertEqual(synthesizer.pendingCompletionCount, 1)

        synthesizer.finishNext()
        try coordinator.announceDeferredIfNeeded()

        XCTAssertNil(store.loadActiveCommandCheckpoint())
        XCTAssertEqual(
            synthesizer.spoken,
            ["Replay after interruption.", "Replay after interruption."]
        )
        XCTAssertEqual(coordinator.lastSpoken, "Replay after interruption.")
    }

    func testBackgroundPresentationDefersSpeechUntilForegroundExactlyOnce() throws {
        let url = Self.temporarySQLiteURL("deferred-speech")
        defer { Self.removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        let scope = try XCTUnwrap(ActiveCommandScope(
            backendURL: URL(string: "https://api.example.com"),
            ownerUserID: "usr_stable"
        ))
        XCTAssertTrue(store.saveActiveCommandCheckpoint(Self.checkpoint(
            phase: .terminalPendingPresentation,
            commandID: "cmd_deferred_voice",
            state: "succeeded",
            version: 4,
            presentation: Self.presentation(
                displayText: "The command completed in the background.",
                voiceScript: "Background command complete.",
                terminal: true
            )
        )))

        var isForeground = false
        let synthesizer = RecordingVoiceSynthesizer()
        let coordinator = ActiveCommandCheckpointCoordinator(
            store: store,
            synthesizer: synthesizer,
            isSpeechAllowed: { isForeground }
        )

        let restored = try XCTUnwrap(coordinator.restore(scope: scope))
        XCTAssertEqual(restored.message, "The command completed in the background.")
        XCTAssertTrue(synthesizer.spoken.isEmpty)
        XCTAssertEqual(synthesizer.stopCount, 0)
        XCTAssertNil(store.loadActiveCommandCheckpoint()?.lastAnnouncedVersion)

        isForeground = true
        try coordinator.announceDeferredIfNeeded()
        try coordinator.announceDeferredIfNeeded()

        XCTAssertEqual(synthesizer.spoken, ["Background command complete."])
        XCTAssertEqual(synthesizer.stopCount, 1)
        XCTAssertEqual(store.loadActiveCommandCheckpoint()?.lastAnnouncedVersion, 4)
    }

    func testMarkPresentedWhileSpeechDeferredSurvivesRelaunchAndDoesNotResurrectAfterAnnouncement() throws {
        let url = Self.temporarySQLiteURL("presented-before-deferred-speech")
        defer { Self.removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        let scope = try XCTUnwrap(ActiveCommandScope(
            backendURL: URL(string: "https://api.example.com"),
            ownerUserID: "usr_stable"
        ))
        XCTAssertTrue(store.saveActiveCommandCheckpoint(Self.checkpoint(
            phase: .terminalPendingPresentation,
            commandID: "cmd_presented_before_speech",
            state: "succeeded",
            version: 6,
            presentation: Self.presentation(
                displayText: "The command completed while backgrounded.",
                voiceScript: "Deferred command complete.",
                terminal: true
            )
        )))

        var isForeground = false
        let firstSynthesizer = RecordingVoiceSynthesizer()
        let first = ActiveCommandCheckpointCoordinator(
            store: store,
            synthesizer: firstSynthesizer,
            isSpeechAllowed: { isForeground }
        )
        _ = try XCTUnwrap(first.restore(scope: scope))
        try first.markPresented(commandID: "cmd_presented_before_speech", version: 6)

        XCTAssertTrue(firstSynthesizer.spoken.isEmpty)
        XCTAssertEqual(store.loadActiveCommandCheckpoint()?.lastPresentedVersion, 6)
        XCTAssertNil(store.loadActiveCommandCheckpoint()?.lastAnnouncedVersion)

        let reopenedStore = SQLiteStore(databaseURL: url)
        let reopenedSynthesizer = RecordingVoiceSynthesizer()
        let reopened = ActiveCommandCheckpointCoordinator(
            store: reopenedStore,
            synthesizer: reopenedSynthesizer,
            isSpeechAllowed: { isForeground }
        )
        _ = try XCTUnwrap(reopened.restore(scope: scope))
        XCTAssertTrue(reopenedSynthesizer.spoken.isEmpty)

        isForeground = true
        try reopened.announceDeferredIfNeeded()
        try reopened.announceDeferredIfNeeded()
        try reopened.markPresented(commandID: "cmd_presented_before_speech", version: 6)

        XCTAssertEqual(reopenedSynthesizer.spoken, ["Deferred command complete."])
        XCTAssertEqual(reopenedSynthesizer.stopCount, 1)
        XCTAssertNil(reopenedStore.loadActiveCommandCheckpoint())

        let finalSynthesizer = RecordingVoiceSynthesizer()
        let finalReopen = ActiveCommandCheckpointCoordinator(
            store: SQLiteStore(databaseURL: url),
            synthesizer: finalSynthesizer
        )
        XCTAssertNil(try finalReopen.restore(scope: scope))
        XCTAssertTrue(finalSynthesizer.spoken.isEmpty)
    }

    func testDiscardInMemoryStopsActiveBackendSpeech() throws {
        let url = Self.temporarySQLiteURL("discard-speech")
        defer { Self.removeSQLiteArtifacts(at: url) }
        let store = SQLiteStore(databaseURL: url)
        let scope = try XCTUnwrap(ActiveCommandScope(
            backendURL: URL(string: "https://api.example.com"),
            ownerUserID: "usr_stable"
        ))
        XCTAssertTrue(store.saveActiveCommandCheckpoint(Self.checkpoint(
            phase: .terminalPendingPresentation,
            commandID: "cmd_private_voice",
            state: "succeeded",
            version: 3,
            presentation: Self.presentation(
                displayText: "The server completed the command.",
                voiceScript: "Private backend-owned result.",
                terminal: true
            )
        )))

        let synthesizer = RecordingVoiceSynthesizer()
        let coordinator = ActiveCommandCheckpointCoordinator(
            store: store,
            synthesizer: synthesizer
        )
        _ = try coordinator.restore(scope: scope)
        XCTAssertEqual(synthesizer.spoken, ["Private backend-owned result."])
        XCTAssertEqual(synthesizer.stopCount, 1)

        coordinator.discardInMemory()

        XCTAssertEqual(synthesizer.stopCount, 2)
        XCTAssertNil(coordinator.checkpoint)
        XCTAssertNil(coordinator.presentation)
        XCTAssertNil(coordinator.lastSpoken)
    }

    private nonisolated static func response(
        commandID: String = "cmd_server_1",
        state: String,
        result: JSONValue?,
        args: [String: JSONValue] = [:],
        presentation: CommandPresentation? = nil,
        confirmationToken: String? = nil,
        version: Int = 7
    ) throws -> CommandResponse {
        CommandResponse(
            command_id: commandID,
            state: state,
            command: try envelope(commandID: commandID, args: args),
            action: CommandActionMetadata(
                title: "Send message",
                risk: "high",
                confirm_required: true,
                reversible: false
            ),
            presentation: presentation,
            confirmation_token: confirmationToken,
            result: result,
            error: nil,
            undo_command_id: nil,
            version: version,
            created_at: nil,
            updated_at: nil
        )
    }

    private nonisolated static func envelope(
        commandID: String,
        idempotencyKey: String? = nil,
        args: [String: JSONValue] = [:]
    ) throws -> CommandEnvelope {
        try CommandEnvelope(
            commandID: commandID,
            intent: "send_message",
            args: args,
            riskLevel: .high,
            needsConfirmation: true,
            idempotencyKey: idempotencyKey ?? "idem_\(commandID)",
            confidence: 0.99,
            locale: "en-HK",
            timezone: "Asia/Hong_Kong"
        )
    }

    private nonisolated static func presentation(
        locale: String = "en-HK",
        displayText: String = "The command is queued.",
        voiceScript: String? = nil,
        terminal: Bool = false
    ) -> CommandPresentation {
        CommandPresentation(
            schema_version: 1,
            code: "command.update",
            locale: locale,
            display_text: displayText,
            voice_script: voiceScript,
            terminal: terminal
        )
    }

    private nonisolated static func checkpoint(
        phase: ActiveCommandCheckpoint.Phase,
        commandID: String,
        state: String,
        version: Int,
        presentation: CommandPresentation? = nil
    ) -> ActiveCommandCheckpoint {
        ActiveCommandCheckpoint(
            phase: phase,
            commandID: commandID,
            backendState: state,
            backendVersion: version,
            envelope: nil,
            validatedPresentation: presentation?.validated(for: state),
            lastAnnouncedVersion: nil,
            backendOrigin: "https://api.example.com:443",
            ownerUserID: "usr_stable",
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    private nonisolated static func temporarySQLiteURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-knock-\(label)-\(UUID().uuidString).sqlite")
    }

    private nonisolated static func removeSQLiteArtifacts(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

@MainActor
final class AppStoreVoiceLifecycleTests: XCTestCase {
    func testInactiveStopsBackendSpeechWhenVoiceControllerIsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-knock-lifecycle-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let synthesizer = RecordingVoiceSynthesizer()
        let store = AppStore(
            localStore: SQLiteStore(databaseURL: url),
            commandSynthesizer: synthesizer,
            backgroundReconciliationDispatcher: BackgroundReconciliationDispatcher()
        )
        XCTAssertNil(store.voiceController)
        let stopsBeforeTransition = synthesizer.stopCount

        store.suspendVoiceForSceneTransition()

        XCTAssertEqual(synthesizer.stopCount, stopsBeforeTransition + 1)
    }

    func testApiBaseChangeInvalidatesVoiceGenerationBeforeClientMutation() throws {
        let defaults = UserDefaults.standard
        let previousAPIBase = defaults.string(forKey: "vab.apiBase")
        defer {
            if let previousAPIBase {
                defaults.set(previousAPIBase, forKey: "vab.apiBase")
            } else {
                defaults.removeObject(forKey: "vab.apiBase")
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-knock-scope-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let synthesizer = RecordingVoiceSynthesizer()
        let store = AppStore(
            localStore: SQLiteStore(databaseURL: url),
            commandSynthesizer: synthesizer,
            backgroundReconciliationDispatcher: BackgroundReconciliationDispatcher()
        )
        let originalURL = store.client.baseURL
        let originalGeneration = store.localVoiceScopeGeneration
        var urlsObservedAtStop: [URL?] = []
        synthesizer.onStop = { [weak store] in
            urlsObservedAtStop.append(store?.client.baseURL)
        }
        store.apiBase = originalURL == URL(string: "http://127.0.0.1:39281")
            ? "http://127.0.0.1:39282"
            : "http://127.0.0.1:39281"
        XCTAssertTrue(store.applyApiBase())

        XCTAssertEqual(store.localVoiceScopeGeneration, originalGeneration + 1)
        XCTAssertFalse(urlsObservedAtStop.isEmpty)
        XCTAssertTrue(urlsObservedAtStop.allSatisfy { $0 == originalURL })
        XCTAssertNil(store.voiceController)
        XCTAssertEqual(store.voiceModelStatus, "Not prepared")
    }
}

@MainActor
final class AppStoreServerOwnedUndoTests: XCTestCase {
    func testReversibleSuccessWithoutServerAuthorizationClearsStaleUndo() {
        withStore { store in
            store.consumeCommandApplication(.init(
                response: response(undoCommandID: "cmd_undo", version: 7),
                outcome: .applied
            ))
            XCTAssertEqual(store.undoableCommandID, "cmd_undo")

            store.consumeCommandApplication(.init(
                response: response(undoCommandID: nil, version: 8),
                outcome: .applied
            ))

            XCTAssertNil(store.undoableCommandID)
        }
    }

    func testExactServerAuthorizedUndoAppearsAndSurvivesIdempotentReplay() {
        withStore { store in
            let authorized = response(undoCommandID: "cmd_undo", version: 7)
            store.consumeCommandApplication(.init(response: authorized, outcome: .applied))
            XCTAssertEqual(store.undoableCommandID, "cmd_undo")

            store.consumeCommandApplication(.init(response: authorized, outcome: .idempotent))
            XCTAssertEqual(store.undoableCommandID, "cmd_undo")

            let mismatched = response(undoCommandID: "cmd_other", version: 8)
            store.consumeCommandApplication(.init(response: mismatched, outcome: .applied))
            XCTAssertNil(store.undoableCommandID)
        }
    }

    func testSameVersionExpiryAndUndoResultTransitionClearAuthorization() {
        withStore { store in
            store.consumeCommandApplication(.init(
                response: response(undoCommandID: "cmd_undo", version: 7),
                outcome: .applied
            ))

            // The backend's TTL is evaluated at response time and can expire
            // without incrementing the command version.
            store.consumeCommandApplication(.init(
                response: response(undoCommandID: nil, version: 7),
                outcome: .idempotent
            ))
            XCTAssertNil(store.undoableCommandID)

            store.consumeCommandApplication(.init(
                response: response(undoCommandID: "cmd_undo", version: 8),
                outcome: .applied
            ))
            store.consumeCommandApplication(.init(
                response: response(
                    result: .object([
                        "kind": .string("reminder"),
                        "undo": .object(["status": .string("cancelled")]),
                    ]),
                    undoCommandID: nil,
                    version: 9
                ),
                outcome: .applied
            ))
            XCTAssertNil(store.undoableCommandID)
        }
    }

    private func withStore(_ body: (AppStore) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-knock-server-undo-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        body(AppStore(
            localStore: SQLiteStore(databaseURL: url),
            commandSynthesizer: RecordingVoiceSynthesizer(),
            backgroundReconciliationDispatcher: BackgroundReconciliationDispatcher()
        ))
    }

    private func response(
        result: JSONValue? = .object(["kind": .string("reminder")]),
        undoCommandID: String?,
        version: Int
    ) -> CommandResponse {
        CommandResponse(
            command_id: "cmd_undo",
            state: "succeeded",
            command: nil,
            action: CommandActionMetadata(
                title: "Create reminder",
                risk: "low",
                confirm_required: false,
                reversible: true
            ),
            presentation: nil,
            confirmation_token: nil,
            result: result,
            error: nil,
            undo_command_id: undoCommandID,
            version: version,
            created_at: nil,
            updated_at: nil
        )
    }
}

import XCTest
@testable import VoiceAgentBridge

private final class RecordingVoiceSynthesizer: VoiceSynthesizing {
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0

    func speak(_ text: String) {
        spoken.append(text)
    }

    func stop() {
        stopCount += 1
    }
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

    func testReducerRejectsWrongIDAndLowerVersionAndMakesEqualVersionIdempotent() throws {
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
                response: try Self.response(commandID: "cmd_current", state: "failed", result: nil, version: 8),
                expectedCommandID: "cmd_current",
                current: current
            ),
            .idempotent
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
        XCTAssertNil(try reopened.restore(scope: scope))
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
        XCTAssertNil(try reopened.restore(scope: scope))
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

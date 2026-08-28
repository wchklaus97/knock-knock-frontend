import Foundation
import XCTest
@testable import VoiceAgentBridge

/// Pins the dynamic Home voice routing table without a device:
/// four English shortcuts stay local even when an agent is selected;
/// everything else Asks the selected agent with the original transcript.
@MainActor
final class DynamicVoiceWorkflowTests: XCTestCase {
    private let mixedScreenshotUtterance = "今日天氣點樣幫我發俾 Peter"
    private let agentLabel = "cursor-staging"

    func testPreflightPinsLocalEnglishShortcutsAndAsksUnknownSpeech() throws {
        let local: [(String, String)] = [
            ("search history", "search_history"),
            ("Search my history", "search_history"),
            ("Remind me tomorrow at 9 AM to call John", "create_reminder"),
            ("Draft a note about the launch", "create_draft"),
            ("Send John a message saying hello", "send_message"),
            ("Say him a message", "send_message"),
        ]
        for (utterance, intent) in local {
            XCTAssertEqual(
                try LocalVoiceUtterancePreflight.intentHint(for: utterance),
                intent,
                utterance
            )
            XCTAssertTrue(
                LocalVoiceUtterancePreflight.prefersLocalCommandPath(for: utterance),
                utterance
            )
        }

        for utterance in [
            "Help with APNs",
            "今天天气怎么样",
            mixedScreenshotUtterance,
        ] {
            XCTAssertNil(
                try LocalVoiceUtterancePreflight.intentHint(for: utterance),
                utterance
            )
            XCTAssertFalse(
                LocalVoiceUtterancePreflight.prefersLocalCommandPath(for: utterance),
                utterance
            )
        }

        XCTAssertTrue(LiveSpeechTranscriptChooser.containsCJK("发消息给 John 说你好"))
        XCTAssertTrue(LiveSpeechTranscriptChooser.containsCJK("今天天气怎么样"))
        XCTAssertTrue(LiveSpeechTranscriptChooser.containsCJK(mixedScreenshotUtterance))
        XCTAssertFalse(LiveSpeechTranscriptChooser.containsCJK("Help with APNs"))
        XCTAssertFalse(LiveSpeechTranscriptChooser.containsCJK("search history"))
    }

    func testHomeVoiceDockCopyAskingAndAskedAreNotUnderstanding() {
        let asking = HomeVoiceDockCopy.make(
            voice: .asking(agentLabel),
            isFollowUpListen: false,
            targetLabel: agentLabel,
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(asking.status, "Asking")
        XCTAssertEqual(asking.action, "Asking \(agentLabel)…")
        XCTAssertNotEqual(asking.status, "Understanding…")
        XCTAssertNotEqual(asking.action, "Understanding your command…")

        let asked = HomeVoiceDockCopy.make(
            voice: .asked(agentLabel),
            isFollowUpListen: false,
            targetLabel: agentLabel,
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(asked.status, "Sent")
        XCTAssertEqual(asked.action, "Sent to \(agentLabel).")
        XCTAssertNotEqual(asked.status, "Understanding…")
        XCTAssertNotEqual(asked.action, "Understanding your command…")

        let processing = HomeVoiceDockCopy.make(
            voice: .processing,
            isFollowUpListen: false,
            targetLabel: agentLabel,
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(processing.status, "Understanding…")
        XCTAssertEqual(processing.action, "Understanding your command…")
    }

    func testAskDockTitleUsesTheSameSelectedAgentLabelAsRouting() {
        let none = HomeVoiceDockCopy.make(
            voice: .idle,
            isFollowUpListen: false,
            targetLabel: nil,
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(none.title, "Voice")

        let selected = HomeVoiceDockCopy.make(
            voice: .idle,
            isFollowUpListen: false,
            targetLabel: agentLabel,
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(selected.title, "Ask \(agentLabel)")
        XCTAssertEqual(
            VoiceAskTarget(agentID: "agt_cursor", label: agentLabel).label,
            agentLabel
        )
    }

    func testSearchHistoryStaysLocalEvenWhenAnAgentIsSelected() async throws {
        try await assertLocalShortcut(
            utterance: "search history",
            expectedIntent: "search_history",
            canned: Self.searchEnvelope()
        )
    }

    func testSearchMyHistoryStaysLocalEvenWhenAnAgentIsSelected() async throws {
        try await assertLocalShortcut(
            utterance: "Search my history",
            expectedIntent: "search_history",
            canned: Self.searchEnvelope()
        )
    }

    func testRemindMeTomorrowStaysLocalEvenWhenAnAgentIsSelected() async throws {
        try await assertLocalShortcut(
            utterance: "Remind me tomorrow at 9 AM to call John",
            expectedIntent: "create_reminder",
            canned: Self.reminderEnvelope()
        )
    }

    func testDraftANoteStaysLocalEvenWhenAnAgentIsSelected() async throws {
        try await assertLocalShortcut(
            utterance: "Draft a note about the launch",
            expectedIntent: "create_draft",
            canned: Self.draftEnvelope()
        )
    }

    func testSendJohnAMessageStaysLocalEvenWhenAnAgentIsSelected() async throws {
        try await assertLocalShortcut(
            utterance: "Send John a message saying hello",
            expectedIntent: "send_message",
            canned: Self.sendEnvelope()
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
        let submitted = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            submitAsk: { _, _ in
                asked.value = true
                return Self.askResponse()
            }
        ) { _ in
            submitted.value = true
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
        XCTAssertFalse(asked.value)
        XCTAssertFalse(submitted.value)
        XCTAssertEqual(generator.transcripts, ["Say him a message"])
        XCTAssertEqual(synthesizer.spoken, ["Who should I send this to?"])
    }

    func testHelpWithAPNsAsksExactTranscriptWhenAgentIsSelected() async throws {
        try await assertAsk(utterance: "Help with APNs")
    }

    func testChineseWeatherAsksExactTranscriptWhenAgentIsSelected() async throws {
        try await assertAsk(utterance: "今天天气怎么样")
    }

    func testMixedScreenshotUtteranceAsksExactTranscriptWhenAgentIsSelected() async throws {
        try await assertAsk(utterance: mixedScreenshotUtterance)
    }

    func testChineseSendAsksExactTranscriptWhenAgentIsSelected() async throws {
        try await assertAsk(utterance: "发消息给 John 说你好")
    }

    func testUnknownUtteranceWithoutSelectedAgentAsksUserToSelectOne() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let postedAsk = VoiceTestBox(false)
        let submitted = VoiceTestBox(false)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            askTarget: { nil },
            submitAsk: { _, _ in
                postedAsk.value = true
                return Self.askResponse()
            }
        ) { _ in
            submitted.value = true
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Help with APNs", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            controller.state == .clarificationRequired(.selectAgent)
        }

        XCTAssertEqual(controller.state, .clarificationRequired(.selectAgent))
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertFalse(postedAsk.value)
        XCTAssertFalse(submitted.value)
        XCTAssertEqual(synthesizer.spoken, ["Select an agent first."])
    }

    func testListeningWindowMatchesWorkerExclusiveEdgeAtExact90Seconds() {
        XCTAssertEqual(AgentListening.windowSeconds, 90)
        let lastSeen = "2026-08-18T12:00:00.000Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seen = formatter.date(from: lastSeen)!
        let justInside = seen.addingTimeInterval(89)
        let exactNinety = seen.addingTimeInterval(90)
        let justPast = seen.addingTimeInterval(91)
        XCTAssertTrue(AgentListening.isListening(lastSeenAt: lastSeen, now: justInside))
        XCTAssertFalse(AgentListening.isListening(lastSeenAt: lastSeen, now: exactNinety))
        XCTAssertFalse(AgentListening.isListening(lastSeenAt: lastSeen, now: justPast))
        XCTAssertEqual(exactNinety.timeIntervalSince(seen), 90.000, accuracy: 0.000_000_1)
    }

    func testThirteenProKeepsDeterministicParserAndHomePrepareIsNotSettings() {
        XCTAssertEqual(
            LocalVoiceRuntimePolicy.strategy(machineIdentifier: "iPhone14,2"),
            .deterministicParser
        )
        XCTAssertEqual(HomeVoicePrepareDockCopy.title, "Enable voice")
        XCTAssertFalse(HomeVoicePrepareDockCopy.title.localizedCaseInsensitiveContains("Settings"))
    }

    func testVoiceDockWithZeroUsableListenersIsUnavailable() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resolution = VoiceAskAgentResolver.targetResolution(
            selectedId: nil,
            agents: [],
            now: now
        )
        XCTAssertEqual(resolution, .unavailable)
        XCTAssertNil(resolution.target)
        let copy = HomeVoiceDockCopy.make(
            voice: .idle,
            isFollowUpListen: false,
            targetLabel: nil,
            presentation: nil,
            isAwaitingConfirmation: false,
            targetResolution: resolution
        )
        XCTAssertEqual(copy.title, "No agents listening")
        XCTAssertNotEqual(copy.status, "Ready")
    }

    func testSubmittedVoiceDockWithStaleTargetNeverReportsReady() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let stale = voiceTargetAgent("agt_stale_submitted", expiresIn: -1, now: now)
        let resolution = VoiceAskAgentResolver.targetResolution(
            selectedId: stale.agent_id,
            agents: [stale],
            now: now
        )
        XCTAssertEqual(resolution, .unavailable)

        let copy = HomeVoiceDockCopy.make(
            voice: .submitted("cmd_timed_out"),
            isFollowUpListen: false,
            targetLabel: stale.label,
            presentation: nil,
            isAwaitingConfirmation: false,
            targetResolution: resolution
        )

        XCTAssertEqual(copy.title, "No agents listening")
        XCTAssertEqual(copy.status, "Unavailable")
        XCTAssertNotEqual(copy.status, "Ready")
    }

    func testVoiceDockAutoResolvesSoleUsableListener() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let sole = voiceTargetAgent("agt_sole", expiresIn: 60, now: now)
        let resolution = VoiceAskAgentResolver.targetResolution(
            selectedId: nil,
            agents: [sole],
            now: now
        )
        let target = try XCTUnwrap(resolution.target)
        XCTAssertEqual(target.agentID, sole.agent_id)
        let copy = HomeVoiceDockCopy.make(
            voice: .idle,
            isFollowUpListen: false,
            targetLabel: target.label,
            presentation: nil,
            isAwaitingConfirmation: false,
            targetResolution: resolution
        )
        XCTAssertEqual(copy.status, "Ready")
        XCTAssertEqual(copy.action, "Tap to talk to \(target.label)")
    }

    func testVoiceDockRequiresSelectionForMultipleUsableListeners() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = voiceTargetAgent("agt_first", expiresIn: 60, now: now)
        let second = voiceTargetAgent("agt_second", expiresIn: 60, now: now)
        let resolution = VoiceAskAgentResolver.targetResolution(
            selectedId: nil,
            agents: [first, second],
            now: now
        )
        guard case let .selectionRequired(targets) = resolution else {
            return XCTFail("Expected an explicit selection requirement")
        }
        XCTAssertEqual(targets.map(\.agentID), [first.agent_id, second.agent_id])
        XCTAssertNil(resolution.target)
        let copy = HomeVoiceDockCopy.make(
            voice: .idle,
            isFollowUpListen: false,
            targetLabel: nil,
            presentation: nil,
            isAwaitingConfirmation: false,
            targetResolution: resolution
        )
        XCTAssertEqual(copy.title, "Select an agent")
        XCTAssertNotEqual(copy.status, "Ready")
    }

    func testVoiceDockResolvesValidExplicitSelectionAmongMultipleListeners() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = voiceTargetAgent("agt_first", expiresIn: 60, now: now)
        let selected = voiceTargetAgent("agt_selected", expiresIn: 60, now: now)
        let resolution = VoiceAskAgentResolver.targetResolution(
            selectedId: selected.agent_id,
            agents: [first, selected],
            now: now
        )
        XCTAssertEqual(try XCTUnwrap(resolution.target).agentID, selected.agent_id)
    }

    func testVoiceDockRejectsStaleSelectionWithoutRetargetingAmbiguousListeners() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let stale = voiceTargetAgent("agt_stale", expiresIn: -1, now: now)
        let first = voiceTargetAgent("agt_first", expiresIn: 60, now: now)
        let second = voiceTargetAgent("agt_second", expiresIn: 60, now: now)
        let resolution = VoiceAskAgentResolver.targetResolution(
            selectedId: stale.agent_id,
            agents: [stale, first, second],
            now: now
        )
        guard case let .selectionRequired(targets) = resolution else {
            return XCTFail("A stale pick must not silently retarget an ambiguous listener set")
        }
        XCTAssertEqual(targets.map(\.agentID), [first.agent_id, second.agent_id])
        XCTAssertNil(resolution.target)
    }

    private func voiceTargetAgent(
        _ id: String,
        expiresIn seconds: TimeInterval,
        now: Date
    ) -> Agent {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Agent(
            agent_id: id,
            user_id: "usr_voice_target",
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

    func testAskFailsClosedWhenAgentIsNotListening() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let received = VoiceTestBox<String?>(nil)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            submitAsk: { transcript, _ in
                received.value = transcript
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
            XCTFail("Local command must not POST when Ask fails closed")
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript("Help with APNs", isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            controller.state == .clarificationRequired(.agentNotListening)
        }

        XCTAssertEqual(received.value, "Help with APNs")
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertEqual(controller.state, .clarificationRequired(.agentNotListening))
        XCTAssertEqual(synthesizer.spoken, ["\(agentLabel) is not listening."])
    }

    private func assertLocalShortcut(
        utterance: String,
        expectedIntent: String,
        canned: Data
    ) async throws {
        XCTAssertEqual(
            try LocalVoiceUtterancePreflight.intentHint(for: utterance),
            expectedIntent
        )
        XCTAssertTrue(LocalVoiceUtterancePreflight.prefersLocalCommandPath(for: utterance))

        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        generator.cannedResult = .success(canned)
        let synthesizer = RecordingVoiceSynthesizer()
        let asked = VoiceTestBox(false)
        let submittedIntent = VoiceTestBox<String?>(nil)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            submitAsk: { _, _ in
                asked.value = true
                return Self.askResponse()
            }
        ) { envelope in
            submittedIntent.value = envelope.intent
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript(utterance, isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            if case .submitted = controller.state { return true }
            return controller.state == .processing
        }

        if controller.state == .processing {
            let processingCopy = dockCopy(controller)
            XCTAssertEqual(processingCopy.status, "Understanding…")
            XCTAssertEqual(processingCopy.action, "Understanding your command…")
        }

        await waitUntil(timeout: 1) {
            if case .submitted = controller.state { return true }
            return false
        }

        XCTAssertEqual(generator.transcripts, [utterance])
        XCTAssertFalse(asked.value)
        XCTAssertEqual(submittedIntent.value, expectedIntent)
        XCTAssertEqual(controller.state, .submitted("cmd_voice_1"))
        XCTAssertNotEqual(controller.state, .asking(agentLabel))
        XCTAssertNotEqual(controller.state, .asked(agentLabel))
    }

    private func assertAsk(utterance: String) async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let received = VoiceTestBox<String?>(nil)
        let submitted = VoiceTestBox(false)
        let askGate = VoiceTestBox<CheckedContinuation<Void, Never>?>(nil)
        let controller = makeController(
            generator: generator,
            capture: capture,
            synthesizer: synthesizer,
            submitAsk: { transcript, _ in
                received.value = transcript
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    askGate.value = continuation
                }
                return Self.askResponse()
            }
        ) { _ in
            submitted.value = true
            return try Self.response()
        }

        controller.start()
        capture.emitTranscript(utterance, isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            askGate.value != nil
        }
        defer {
            if let continuation = askGate.value {
                askGate.value = nil
                continuation.resume()
            }
        }

        XCTAssertEqual(controller.state, .asking(agentLabel), utterance)
        XCTAssertNotEqual(controller.state, .processing, utterance)
        let askingCopy = dockCopy(controller)
        XCTAssertEqual(askingCopy.status, "Asking", utterance)
        XCTAssertEqual(askingCopy.action, "Asking \(agentLabel)…", utterance)
        XCTAssertNotEqual(askingCopy.status, "Understanding…", utterance)
        XCTAssertNotEqual(askingCopy.action, "Understanding your command…", utterance)

        if let continuation = askGate.value {
            askGate.value = nil
            continuation.resume()
        }
        await waitUntil(timeout: 1) {
            controller.state == .asked(self.agentLabel)
        }

        XCTAssertEqual(received.value, utterance)
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertFalse(submitted.value)
        XCTAssertEqual(controller.state, .asked(agentLabel))
        XCTAssertNotEqual(controller.state, .processing, utterance)
        XCTAssertEqual(synthesizer.spoken, ["Sent to \(agentLabel)."])
        let askedCopy = dockCopy(controller)
        XCTAssertEqual(askedCopy.status, "Sent", utterance)
        XCTAssertEqual(askedCopy.action, "Sent to \(agentLabel).", utterance)
        XCTAssertNotEqual(askedCopy.status, "Understanding…", utterance)
        XCTAssertNotEqual(askedCopy.action, "Understanding your command…", utterance)
    }

    private func dockCopy(
        _ controller: LocalVoiceCommandController
    ) -> HomeVoiceDockCopy {
        HomeVoiceDockCopy.make(
            voice: controller.state,
            isFollowUpListen: controller.isFollowUpListen,
            targetLabel: agentLabel,
            presentation: nil,
            isAwaitingConfirmation: false
        )
    }

    private func makeController(
        generator: ControlledCommandGenerator,
        capture: ControlledVoiceCapture,
        synthesizer: RecordingVoiceSynthesizer,
        askTarget: @escaping () -> VoiceAskTarget? = {
            VoiceAskTarget(agentID: "agt_home", label: "cursor-staging")
        },
        submitAsk: (@Sendable (String, VoiceAskTarget) async throws -> PhoneAskResponse)?,
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
            generationTimeoutNanoseconds: 15_000_000_000,
            followUpListenDelayNanoseconds: 0
        )
    }

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

    private nonisolated static func searchEnvelope() -> Data {
        envelopeJSON(
            intent: "search_history",
            args: #"{"q":"history"}"#,
            riskLevel: "low",
            needsConfirmation: false
        )
    }

    private nonisolated static func reminderEnvelope() -> Data {
        envelopeJSON(
            intent: "create_reminder",
            args: #"{"title":"Call John","due_at":"2035-01-15T01:00:00.000Z"}"#,
            riskLevel: "low",
            needsConfirmation: false
        )
    }

    private nonisolated static func draftEnvelope() -> Data {
        envelopeJSON(
            intent: "create_draft",
            args: #"{"body":"about the launch"}"#,
            riskLevel: "low",
            needsConfirmation: false
        )
    }

    private nonisolated static func sendEnvelope() -> Data {
        envelopeJSON(
            intent: "send_message",
            args: #"{"recipient":"John","body":"hello"}"#,
            riskLevel: "high",
            needsConfirmation: true
        )
    }

    private nonisolated static func envelopeJSON(
        intent: String,
        args: String,
        riskLevel: String,
        needsConfirmation: Bool
    ) -> Data {
        Data("""
        {
          "schema_version": 1,
          "command_id": "cmd_voice_1",
          "intent": "\(intent)",
          "args": \(args),
          "risk_level": "\(riskLevel)",
          "needs_confirmation": \(needsConfirmation),
          "idempotency_key": "idem_voice_1",
          "confidence": 1.0,
          "locale": "en-HK",
          "timezone": "Asia/Hong_Kong"
        }
        """.utf8)
    }

    private nonisolated static func askResponse() -> PhoneAskResponse {
        PhoneAskResponse(
            ask_id: "ask_dynamic",
            agent_id: "agt_home",
            agent_label: "cursor-staging",
            session_id: "ses_ask_dynamic",
            turn_sequence: 1,
            status: "queued"
        )
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
            locale: "en-HK",
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

private final class ControlledVoiceCapture: PushToTalkVoiceCapturing {
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
        self.onTranscript = onTranscript
        self.onStop = onStop
        self.onAbort = onAbort
        self.onError = onError
    }

    func stop() {}
    func abort() {}

    func emitTranscript(_ text: String, isFinal: Bool) {
        onTranscript?(.init(text: text, isFinal: isFinal))
    }

    func emitStop(_ reason: PushToTalkVoiceCapture.StopReason) {
        onStop?(reason)
    }
}

private final class ControlledCommandGenerator: LocalCommandGenerating {
    private let lock = NSLock()
    private var storedTranscripts: [String] = []
    var cannedResult: Result<Data, Error>?
    private var completions: [(Result<Data, Error>) -> Void] = []

    var transcripts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedTranscripts
    }

    func generateCommand(for transcript: String, completion: @escaping (Result<Data, Error>) -> Void) {
        let immediate: Result<Data, Error>?
        lock.lock()
        storedTranscripts.append(transcript)
        immediate = cannedResult
        if immediate == nil {
            completions.append(completion)
        }
        lock.unlock()
        if let immediate {
            completion(immediate)
        }
    }

    func cancelGeneration() {}
}

private final class RecordingVoiceSynthesizer: VoiceSynthesizing {
    private(set) var spoken: [String] = []
    var completeImmediately = true
    private var pendingCompletion: ((VoiceSynthesisResult) -> Void)?

    func speak(_ text: String, completion: @escaping (VoiceSynthesisResult) -> Void) {
        spoken.append(text)
        if completeImmediately {
            completion(.finished)
        } else {
            pendingCompletion = completion
        }
    }

    func stop() {}
}

private final class VoiceTestBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

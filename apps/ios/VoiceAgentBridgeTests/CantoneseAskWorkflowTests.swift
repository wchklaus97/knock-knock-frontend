import Foundation
import XCTest
@testable import VoiceAgentBridge

/// Pins the Home Ask workflow from the 17 Pro Max screenshot without a device:
/// Cantonese/English mixed speech is asked as-is, and a host that is not polling
/// fail-closes to "Not listening" instead of local classification.
@MainActor
final class CantoneseAskWorkflowTests: XCTestCase {
    private let screenshotUtterance = "今日天氣點樣幫我發俾 Peter"
    private let screenshotAgentLabel = "apns-gate-7f413c48-ea7a-4e2b-8d04-c8aeb029a52d"

    func testScreenshotUtteranceStaysTheAskTranscriptAndSkipsLocalCommands() throws {
        XCTAssertTrue(LiveSpeechTranscriptChooser.containsCJK(screenshotUtterance))
        XCTAssertNil(try LocalVoiceUtterancePreflight.intentHint(for: screenshotUtterance))
        XCTAssertFalse(
            LocalVoiceUtterancePreflight.prefersLocalCommandPath(for: screenshotUtterance)
        )
    }

    func testScreenshotDockShowsAskTitleTranscriptFailureWithoutClassification() {
        let copy = HomeVoiceDockCopy.make(
            voice: .clarificationRequired(.agentNotListening),
            isFollowUpListen: false,
            targetLabel: screenshotAgentLabel,
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(copy.title, "Ask \(screenshotAgentLabel)")
        XCTAssertEqual(copy.status, "Not listening")
        XCTAssertEqual(copy.action, "\(screenshotAgentLabel) is not listening.")
        XCTAssertNotEqual(copy.status, "Understanding…")
        XCTAssertNotEqual(copy.action, "Understanding your command…")
    }

    func testIdleAgentRowRequiresActiveModernListenerFence() {
        let stale = Agent(
            agent_id: "agt_gate",
            user_id: "usr_1",
            label: screenshotAgentLabel,
            host_label: "cli",
            created_at: "2026-08-18T00:00:00Z",
            last_seen_at: "2026-08-18T00:00:00Z"
        )
        let live = Agent(
            agent_id: "agt_cursor",
            user_id: "usr_1",
            label: "cursor-staging",
            host_label: "cli",
            created_at: "2026-08-18T00:00:00Z",
            last_seen_at: "2026-08-18T12:40:00.000Z",
            listener_binding_id: "binding_cursor",
            listener_lease_id: "lease_cursor",
            listener_generation: 1,
            listener_chat_id: "chat_cursor",
            listener_expires_at: "2026-08-18T12:41:00Z"
        )
        let unseen = Agent(
            agent_id: "agt_unseen",
            user_id: "usr_1",
            label: "unseen-host",
            host_label: "cli",
            created_at: "2026-08-18T00:00:00Z",
            last_seen_at: nil
        )
        let justInside = Agent(
            agent_id: "agt_just_inside",
            user_id: "usr_1",
            label: "just-inside",
            host_label: "cli",
            created_at: "2026-08-18T00:00:00Z",
            last_seen_at: "2026-08-18T12:39:01Z",
            listener_binding_id: "binding_inside",
            listener_lease_id: "lease_inside",
            listener_generation: 1,
            listener_chat_id: "chat_inside",
            listener_expires_at: "2026-08-18T12:40:31Z"
        )
        let exactNinety = Agent(
            agent_id: "agt_exact_90",
            user_id: "usr_1",
            label: "exact-90",
            host_label: "cli",
            created_at: "2026-08-18T00:00:00Z",
            last_seen_at: "2026-08-18T12:39:00.000Z"
        )
        let justStale = Agent(
            agent_id: "agt_just_stale",
            user_id: "usr_1",
            label: "just-stale",
            host_label: "cli",
            created_at: "2026-08-18T00:00:00Z",
            last_seen_at: "2026-08-18T12:38:59Z"
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-18T12:40:30Z")!
        let staleSummary = HomeAgentSummary(agent: stale, session: nil, sessionCount: 0)
        let liveSummary = HomeAgentSummary(agent: live, session: nil, sessionCount: 0)
        let unseenSummary = HomeAgentSummary(agent: unseen, session: nil, sessionCount: 0)
        let justInsideSummary = HomeAgentSummary(agent: justInside, session: nil, sessionCount: 0)
        let exactNinetySummary = HomeAgentSummary(agent: exactNinety, session: nil, sessionCount: 0)
        let justStaleSummary = HomeAgentSummary(agent: justStale, session: nil, sessionCount: 0)

        XCTAssertFalse(stale.isListening(now: now))
        XCTAssertTrue(live.isListening(now: now))
        XCTAssertFalse(unseen.isListening(now: now))
        XCTAssertTrue(justInside.isListening(now: now))
        XCTAssertFalse(exactNinety.isListening(now: now))
        XCTAssertFalse(justStale.isListening(now: now))
        XCTAssertFalse(AgentListening.isListening(lastSeenAt: nil, now: now))
        XCTAssertEqual(AgentListening.windowSeconds, 90)

        XCTAssertEqual(AgentHomeRowCopy.stateTitle(for: staleSummary, now: now), "Not listening")
        XCTAssertEqual(AgentHomeRowCopy.stateTitle(for: liveSummary, now: now), "Listening")
        XCTAssertEqual(AgentHomeRowCopy.stateTitle(for: unseenSummary, now: now), "Not listening")
        XCTAssertEqual(AgentHomeRowCopy.stateTitle(for: justInsideSummary, now: now), "Listening")
        XCTAssertEqual(AgentHomeRowCopy.stateTitle(for: exactNinetySummary, now: now), "Not listening")
        XCTAssertEqual(AgentHomeRowCopy.stateTitle(for: justStaleSummary, now: now), "Not listening")

        let idleSummaries = [
            staleSummary, liveSummary, unseenSummary, justInsideSummary, exactNinetySummary,
            justStaleSummary,
        ]
        for summary in idleSummaries {
            XCTAssertNotEqual(
                AgentHomeRowCopy.stateTitle(for: summary, now: now),
                "Connected",
                summary.agent.label
            )
            XCTAssertNotEqual(
                AgentHomeRowCopy.stateTitle(for: summary, now: now),
                ConnectionPillCopy.title(for: .connected),
                summary.agent.label
            )
        }

        XCTAssertEqual(ConnectionPillCopy.title(for: .connected), "Connected")
        XCTAssertEqual(ConnectionPillCopy.title(for: .unavailable), "Offline")
        XCTAssertEqual(ConnectionPillCopy.title(for: .unknown), "Checking")
        XCTAssertEqual(
            AgentHomeRowCopy.sessionTitle(for: staleSummary, scope: .today),
            "No activity in Today"
        )
        XCTAssertEqual(
            AgentHomeRowCopy.sessionTitle(for: liveSummary, scope: .today),
            "No activity in Today"
        )
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

    func testAgentWireDecodingUsesActiveModernListenerLease() throws {
        let now = ISO8601DateFormatter().date(from: "2026-08-26T01:20:00Z")!
        let agent = try JSONDecoder().decode(Agent.self, from: Data("""
        {
          "agent_id": "agt_modern",
          "user_id": "usr_1",
          "label": "cursor-staging",
          "host_label": "cli",
          "created_at": "2026-08-18T00:00:00Z",
          "last_seen_at": "2026-08-18T00:00:00Z",
          "listener_binding_id": "binding_1",
          "listener_lease_id": "lease_1",
          "listener_generation": 7,
          "listener_chat_id": "chat_1",
          "listener_chat_title": "Structured memory",
          "listener_expires_at": "2026-08-26T01:21:00Z",
          "binding_id": "binding_1",
          "lease_id": "lease_1",
          "generation": 7,
          "target_chat_id": "chat_1"
        }
        """.utf8))

        XCTAssertEqual(agent.listener_binding_id, "binding_1")
        XCTAssertEqual(agent.listener_lease_id, "lease_1")
        XCTAssertEqual(agent.listener_generation, 7)
        XCTAssertEqual(agent.listener_chat_id, "chat_1")
        XCTAssertEqual(agent.listener_chat_title, "Structured memory")
        XCTAssertEqual(agent.listener_expires_at, "2026-08-26T01:21:00Z")
        XCTAssertEqual(agent.binding_id, "binding_1")
        XCTAssertEqual(agent.lease_id, "lease_1")
        XCTAssertEqual(agent.generation, 7)
        XCTAssertEqual(agent.target_chat_id, "chat_1")
        XCTAssertTrue(agent.isListening(now: now))
        let target = try XCTUnwrap(agent.voiceAskTarget(now: now))
        XCTAssertTrue(target.hasCompleteFence)
        XCTAssertEqual(target.bindingID, "binding_1")
        XCTAssertEqual(target.leaseID, "lease_1")
        XCTAssertEqual(target.generation, 7)
        XCTAssertEqual(target.targetChatID, "chat_1")
        XCTAssertEqual(
            VoiceAskAgentResolver.resolve(
                selectedId: agent.agent_id,
                agents: [agent],
                now: now
            )?.agent_id,
            agent.agent_id
        )
    }

    func testAgentWireDecodingTreatsExplicitNullModernListenerAsNotListening() throws {
        let now = ISO8601DateFormatter().date(from: "2026-08-26T01:20:00Z")!
        let agent = try JSONDecoder().decode(Agent.self, from: Data("""
        {
          "agent_id": "agt_null",
          "user_id": "usr_1",
          "label": "stale-selection",
          "host_label": "cli",
          "created_at": "2026-08-18T00:00:00Z",
          "last_seen_at": "2026-08-26T01:19:30Z",
          "listener_binding_id": null,
          "listener_lease_id": null,
          "listener_generation": null,
          "listener_chat_id": null,
          "listener_chat_title": null,
          "listener_expires_at": null,
          "binding_id": null,
          "lease_id": null,
          "generation": null,
          "target_chat_id": null
        }
        """.utf8))

        XCTAssertNil(agent.listener_binding_id)
        XCTAssertNil(agent.listener_lease_id)
        XCTAssertNil(agent.listener_generation)
        XCTAssertNil(agent.listener_chat_id)
        XCTAssertNil(agent.listener_chat_title)
        XCTAssertNil(agent.listener_expires_at)
        XCTAssertNil(agent.binding_id)
        XCTAssertNil(agent.lease_id)
        XCTAssertNil(agent.generation)
        XCTAssertNil(agent.target_chat_id)
        XCTAssertFalse(agent.isListening(now: now))
        XCTAssertNil(VoiceAskAgentResolver.resolve(
            selectedId: agent.agent_id,
            agents: [agent],
            now: now
        ))
    }

    func testAgentWireDecodingKeepsLegacyAgentDrainOnly() throws {
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-08-26T01:20:00Z")!
        let agent = try JSONDecoder().decode(Agent.self, from: Data("""
        {
          "agent_id": "agt_legacy",
          "user_id": "usr_1",
          "label": "legacy-agent",
          "host_label": "cli",
          "created_at": "2026-08-18T00:00:00Z",
          "last_seen_at": "2026-08-26T01:19:30Z"
        }
        """.utf8))

        XCTAssertFalse(agent.isListening(now: now))
        XCTAssertFalse(agent.isListening(now: now.addingTimeInterval(60)))
        XCTAssertNil(VoiceAskAgentResolver.resolve(
            selectedId: nil,
            agents: [agent],
            now: now
        ))
        XCTAssertNil(VoiceAskAgentResolver.defaultSelectedId(
            currentId: agent.agent_id,
            agents: [agent],
            now: now
        ))
        XCTAssertNil(agent.voiceAskTarget(now: now))
    }

    func testAgentWireDecodingAcceptsOneCompleteFlatFenceAtomically() throws {
        let now = ISO8601DateFormatter().date(from: "2026-08-26T01:20:00Z")!
        let agent = try JSONDecoder().decode(Agent.self, from: Data("""
        {
          "agent_id": "agt_flat",
          "user_id": "usr_1",
          "label": "flat-agent",
          "host_label": "cli",
          "created_at": "2026-08-18T00:00:00Z",
          "last_seen_at": "2026-08-18T00:00:00Z",
          "listener_expires_at": "2026-08-26T01:21:00Z",
          "binding_id": "binding_flat",
          "lease_id": "lease_flat",
          "generation": 3,
          "target_chat_id": "chat_flat"
        }
        """.utf8))

        XCTAssertEqual(agent.listener_binding_id, "binding_flat")
        XCTAssertEqual(agent.listener_lease_id, "lease_flat")
        XCTAssertEqual(agent.listener_generation, 3)
        XCTAssertEqual(agent.listener_chat_id, "chat_flat")
        XCTAssertTrue(agent.isListening(now: now))
        XCTAssertTrue(try XCTUnwrap(agent.voiceAskTarget(now: now)).hasCompleteFence)
    }

    func testAgentWireDecodingRejectsPartialSchemasWithoutMixingFenceFields() throws {
        let now = ISO8601DateFormatter().date(from: "2026-08-26T01:20:00Z")!
        let agent = try JSONDecoder().decode(Agent.self, from: Data("""
        {
          "agent_id": "agt_partial",
          "user_id": "usr_1",
          "label": "partial-agent",
          "host_label": "cli",
          "created_at": "2026-08-18T00:00:00Z",
          "last_seen_at": "2026-08-26T01:19:30Z",
          "listener_binding_id": "binding_listener",
          "listener_lease_id": "lease_listener",
          "listener_expires_at": "2026-08-26T01:21:00Z",
          "generation": 4,
          "target_chat_id": "chat_flat"
        }
        """.utf8))

        XCTAssertNil(agent.listener_binding_id)
        XCTAssertNil(agent.listener_lease_id)
        XCTAssertNil(agent.listener_generation)
        XCTAssertNil(agent.listener_chat_id)
        XCTAssertNil(agent.binding_id)
        XCTAssertNil(agent.lease_id)
        XCTAssertNil(agent.generation)
        XCTAssertNil(agent.target_chat_id)
        XCTAssertFalse(agent.isListening(now: now))
        XCTAssertNil(agent.voiceAskTarget(now: now))
    }

    func testAgentWireDecodingRejectsConflictingCompleteFenceSchemas() throws {
        let now = ISO8601DateFormatter().date(from: "2026-08-26T01:20:00Z")!
        let agent = try JSONDecoder().decode(Agent.self, from: Data("""
        {
          "agent_id": "agt_conflict",
          "user_id": "usr_1",
          "label": "conflicting-agent",
          "host_label": "cli",
          "created_at": "2026-08-18T00:00:00Z",
          "last_seen_at": "2026-08-26T01:19:30Z",
          "listener_binding_id": "binding_listener",
          "listener_lease_id": "lease_listener",
          "listener_generation": 4,
          "listener_chat_id": "chat_listener",
          "listener_expires_at": "2026-08-26T01:21:00Z",
          "binding_id": "binding_flat",
          "lease_id": "lease_flat",
          "generation": 5,
          "target_chat_id": "chat_flat"
        }
        """.utf8))

        XCTAssertNil(agent.binding_id)
        XCTAssertNil(agent.lease_id)
        XCTAssertNil(agent.generation)
        XCTAssertNil(agent.target_chat_id)
        XCTAssertFalse(agent.isListening(now: now))
        XCTAssertNil(agent.voiceAskTarget(now: now))
    }

    func testScreenshotUtteranceAsksAndFailClosesWhenHostIsNotPolling() async throws {
        let capture = ControlledVoiceCapture()
        let generator = ControlledCommandGenerator()
        let synthesizer = RecordingVoiceSynthesizer()
        let received = VoiceTestBox<String?>(nil)
        let utterance = screenshotUtterance
        let agentLabel = screenshotAgentLabel
        let controller = LocalVoiceCommandController(
            generator: generator,
            submit: { _ in
                XCTFail("Mixed Cantonese speech must not POST a local command")
                throw APIClientError.network("unused")
            },
            capture: capture,
            synthesizer: synthesizer,
            askTarget: {
                VoiceAskTarget(agentID: "agt_gate", label: agentLabel)
            },
            submitAsk: { transcript in
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
            },
            permissionsAreGranted: { true }
        )

        controller.start()
        capture.emitTranscript(utterance, isFinal: true)
        capture.emitStop(.finalTranscript)
        await waitUntil(timeout: 1) {
            controller.state == .clarificationRequired(.agentNotListening)
        }

        XCTAssertEqual(received.value, screenshotUtterance)
        XCTAssertTrue(generator.transcripts.isEmpty)
        XCTAssertEqual(controller.state, .clarificationRequired(.agentNotListening))
        XCTAssertEqual(controller.transcript, screenshotUtterance)
        XCTAssertEqual(
            synthesizer.spoken,
            ["\(screenshotAgentLabel) is not listening."]
        )

        let copy = HomeVoiceDockCopy.make(
            voice: controller.state,
            isFollowUpListen: controller.isFollowUpListen,
            targetLabel: screenshotAgentLabel,
            presentation: nil,
            isAwaitingConfirmation: false
        )
        XCTAssertEqual(copy.title, "Ask \(screenshotAgentLabel)")
        XCTAssertEqual(copy.status, "Not listening")
        XCTAssertEqual(copy.action, "\(screenshotAgentLabel) is not listening.")
    }

    func testAskResolverAutoSwitchesStaleSelectionOnlyForSingleLiveListener() {
        let now = ISO8601DateFormatter().date(from: "2026-08-26T01:20:00Z")!
        let staleCodex = Agent(
            agent_id: "agt_codex",
            user_id: "usr_1",
            label: "codex",
            host_label: "cli",
            created_at: "2026-08-18T00:00:00Z",
            last_seen_at: "2026-08-18T00:00:00Z"
        )
        let liveCursor = Agent(
            agent_id: "agt_cursor",
            user_id: "usr_1",
            label: "cursor-staging",
            host_label: "cli",
            created_at: "2026-08-18T00:00:00Z",
            last_seen_at: "2026-08-26T01:19:30Z",
            listener_binding_id: "binding_cursor",
            listener_lease_id: "lease_cursor",
            listener_generation: 1,
            listener_chat_id: "chat_cursor",
            listener_expires_at: "2026-08-26T01:21:00Z"
        )
        let olderLive = Agent(
            agent_id: "agt_older",
            user_id: "usr_1",
            label: "older-live",
            host_label: "cli",
            created_at: "2026-08-18T00:00:00Z",
            last_seen_at: "2026-08-26T01:19:00Z",
            listener_binding_id: "binding_older",
            listener_lease_id: "lease_older",
            listener_generation: 1,
            listener_chat_id: "chat_older",
            listener_expires_at: "2026-08-26T01:21:00Z"
        )

        XCTAssertEqual(
            VoiceAskAgentResolver.resolve(
                selectedId: staleCodex.agent_id,
                agents: [staleCodex, liveCursor],
                now: now
            )?.agent_id,
            liveCursor.agent_id
        )
        XCTAssertEqual(
            VoiceAskAgentResolver.resolve(
                selectedId: liveCursor.agent_id,
                agents: [staleCodex, liveCursor, olderLive],
                now: now
            )?.agent_id,
            liveCursor.agent_id
        )
        XCTAssertNil(
            VoiceAskAgentResolver.resolve(
                selectedId: staleCodex.agent_id,
                agents: [staleCodex],
                now: now
            )
        )
        XCTAssertNil(
            VoiceAskAgentResolver.resolve(
                selectedId: staleCodex.agent_id,
                agents: [staleCodex, liveCursor, olderLive],
                now: now
            )
        )
        XCTAssertNil(
            VoiceAskAgentResolver.resolve(
                selectedId: nil,
                agents: [staleCodex, liveCursor, olderLive],
                now: now
            )
        )
        XCTAssertEqual(
            VoiceAskAgentResolver.defaultSelectedId(
                currentId: staleCodex.agent_id,
                agents: [staleCodex, liveCursor],
                now: now
            ),
            liveCursor.agent_id
        )
        XCTAssertEqual(
            VoiceAskAgentResolver.defaultSelectedId(
                currentId: liveCursor.agent_id,
                agents: [staleCodex, liveCursor, olderLive],
                now: now
            ),
            liveCursor.agent_id
        )
        XCTAssertNil(
            VoiceAskAgentResolver.defaultSelectedId(
                currentId: staleCodex.agent_id,
                agents: [staleCodex, liveCursor, olderLive],
                now: now
            )
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
    private(set) var transcripts: [String] = []

    func generateCommand(for transcript: String, completion: @escaping (Result<Data, Error>) -> Void) {
        transcripts.append(transcript)
        completion(.failure(LocalCommandEnvelopeCanonicalizerError.clarificationRequired(.unsupportedIntent)))
    }

    func cancelGeneration() {}
}

private final class RecordingVoiceSynthesizer: VoiceSynthesizing {
    private(set) var spoken: [String] = []

    func speak(_ text: String, completion: @escaping (VoiceSynthesisResult) -> Void) {
        spoken.append(text)
        completion(.finished)
    }

    func stop() {}
}

private final class VoiceTestBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

import AVFoundation
import Combine
import Foundation
import Speech

/// Main-thread coordinator for the user-visible push-to-talk flow. It owns no
/// executable action: capture produces a transcript, the local model produces
/// an envelope, and LocalVoiceCommandCoordinator submits only the strict draft.
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

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""

    private let capture: PushToTalkVoiceCapture
    private let coordinator: LocalVoiceCommandCoordinator
    private let synthesizer: VoiceSynthesizing
    private var pressActive = false

    init(
        generator: LocalCommandGenerating,
        submit: @escaping @Sendable (CommandEnvelope) async throws -> CommandResponse,
        capture: PushToTalkVoiceCapture = PushToTalkVoiceCapture(),
        synthesizer: VoiceSynthesizing = SystemVoiceSynthesizer()
    ) {
        self.capture = capture
        coordinator = LocalVoiceCommandCoordinator(generator: generator, submit: submit)
        self.synthesizer = synthesizer
    }

    /// Begins a new recording. The app never keeps the microphone active in
    /// the background; callers must invoke stop() when the press ends.
    func start() {
        guard canStart else { return }
        pressActive = true
        transcript = ""
        if SFSpeechRecognizer.authorizationStatus() == .authorized,
           AVAudioSession.sharedInstance().recordPermission == .granted
        {
            startCapture()
            return
        }
        state = .requestingPermissions

        PushToTalkVoiceCapture.requestPermissions { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.state == .requestingPermissions, self.pressActive else { return }
                switch result {
                case .success:
                    self.startCapture()
                case let .failure(error):
                    self.fail(error)
                }
            }
        }
    }

    /// Ends recording and lets the latest transcript pass through the strict
    /// model/API boundary. Empty or low-confidence drafts become clarification.
    func stop() {
        pressActive = false
        guard state == .listening else { return }
        capture.stop()
    }

    func cancel() {
        pressActive = false
        guard state == .listening else { return }
        capture.stop()
        state = .idle
        transcript = ""
    }

    private func startCapture() {
        do {
            try capture.start(
                onTranscript: { [weak self] partial in
                    guard let self else { return }
                    self.transcript = partial.text
                },
                onStop: { [weak self] _ in
                    guard let self else { return }
                    self.processLatestTranscript()
                },
                onError: { [weak self] error in
                    guard let self else { return }
                    self.fail(error)
                }
            )
            state = .listening
        } catch {
            fail(error)
        }
    }

    private func processLatestTranscript() {
        guard state == .listening else { return }
        state = .processing
        let text = transcript
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let response = try await coordinator.handleTranscript(text) else {
                    state = .clarificationRequired
                    synthesizer.speak("Could you clarify that?")
                    return
                }
                state = .submitted(response.command_id)
                if response.state == "awaiting_confirmation" {
                    synthesizer.speak("Please confirm this action in Knock Knock.")
                } else {
                    synthesizer.speak("Your request was submitted.")
                }
            } catch {
                fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        pressActive = false
        state = .failed(error.localizedDescription)
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

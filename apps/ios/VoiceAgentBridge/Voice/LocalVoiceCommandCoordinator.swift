import Foundation

/// Keeps local speech/model work separate from execution. A local generator
/// can only produce bytes; the coordinator strictly decodes the envelope and
/// then hands it to the authenticated API client for backend validation.
@MainActor
final class LocalVoiceCommandCoordinator {
    enum State: Equatable {
        case idle
        case transcribing
        case drafting
        case submitted(String)
        case clarificationRequired
        case failed
    }

    private(set) var state: State = .idle
    private let generate: LocalCommandGenerating
    private let submit: @Sendable (CommandEnvelope) async throws -> CommandResponse

    init(
        generator: LocalCommandGenerating,
        submit: @escaping @Sendable (CommandEnvelope) async throws -> CommandResponse
    ) {
        self.generate = generator
        self.submit = submit
    }

    func handleTranscript(_ transcript: String) async throws -> CommandResponse? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .clarificationRequired
            return nil
        }

        state = .drafting
        return try await withCheckedThrowingContinuation { continuation in
            generate.generateCommand(for: trimmed) { [weak self] result in
                guard let self else {
                    continuation.resume(throwing: LocalVoiceAdapterError.gemmaRuntimeNotLinked)
                    return
                }
                Task { @MainActor in
                    do {
                        let data = try result.get()
                        let envelope = try CommandEnvelope.decodeStrict(from: data)
                        guard envelope.confidence >= 0.5 else {
                            self.state = .clarificationRequired
                            continuation.resume(returning: nil)
                            return
                        }
                        let response = try await self.submit(envelope)
                        self.state = .submitted(response.command_id)
                        continuation.resume(returning: response)
                    } catch {
                        self.state = .failed
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

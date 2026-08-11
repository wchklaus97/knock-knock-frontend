import Foundation

struct ActiveCommandScope: Equatable {
    let backendOrigin: String
    let ownerUserID: String

    init?(backendURL: URL?, ownerUserID: String?) {
        guard let backendOrigin = Self.origin(for: backendURL),
              let ownerUserID = ownerUserID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ownerUserID.isEmpty
        else { return nil }
        self.backendOrigin = backendOrigin
        self.ownerUserID = ownerUserID
    }

    static func origin(for url: URL?) -> String? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !scheme.isEmpty,
              !host.isEmpty
        else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port ?? (scheme == "https" ? 443 : (scheme == "http" ? 80 : nil))
        guard components.port != nil else { return nil }
        return components.string
    }
}

enum ActiveCommandCheckpointError: LocalizedError, Equatable {
    case commandInProgress(String)
    case persistenceFailed
    case rejectedResponse(ActiveCommandCheckpointReducer.Rejection)
    case currentCommandMissing(String)

    var errorDescription: String? {
        switch self {
        case let .commandInProgress(commandID):
            return "Command \(commandID) is still active. Wait for it to finish before submitting another voice command."
        case .persistenceFailed:
            return "The voice command could not be saved safely, so it was not sent."
        case let .rejectedResponse(reason):
            return "The backend command response was rejected (\(reason.description))."
        case let .currentCommandMissing(commandID):
            return "Command \(commandID) is missing from the backend and cannot be reconciled safely."
        }
    }
}

enum ActiveCommandCheckpointReducer {
    enum Rejection: Equatable {
        case noCurrentCommand
        case staleExpectedCommand
        case responseCommandMismatch
        case missingVersion
        case lowerVersion
        case invalidResponse

        var description: String {
            switch self {
            case .noCurrentCommand: return "no current command"
            case .staleExpectedCommand: return "stale command id"
            case .responseCommandMismatch: return "wrong command id"
            case .missingVersion: return "missing command version"
            case .lowerVersion: return "lower command version"
            case .invalidResponse: return "invalid command state"
            }
        }
    }

    enum ResponseResult: Equatable {
        case replace(ActiveCommandCheckpoint)
        case idempotent
        case rejected(Rejection)
    }

    enum NotFoundResult: Equatable {
        case replay(CommandEnvelope)
        case stale
        case unresolved
    }

    static func start(
        current: ActiveCommandCheckpoint?,
        envelope: CommandEnvelope,
        scope: ActiveCommandScope,
        createdAt: Date
    ) throws -> ActiveCommandCheckpoint {
        if let current, current.phase != .terminalPendingPresentation {
            throw ActiveCommandCheckpointError.commandInProgress(current.commandID)
        }
        let checkpoint = ActiveCommandCheckpoint(
            phase: .submitting,
            commandID: envelope.commandID,
            backendState: nil,
            backendVersion: nil,
            envelope: envelope,
            validatedPresentation: nil,
            pendingConfirmation: nil,
            lastPresentedVersion: nil,
            lastAnnouncedVersion: nil,
            backendOrigin: scope.backendOrigin,
            ownerUserID: scope.ownerUserID,
            createdAt: createdAt
        )
        guard checkpoint.isStructurallyValid else {
            throw ActiveCommandCheckpointError.rejectedResponse(.invalidResponse)
        }
        return checkpoint
    }

    static func apply(
        response: CommandResponse,
        expectedCommandID: String,
        current: ActiveCommandCheckpoint?
    ) -> ResponseResult {
        guard let current else { return .rejected(.noCurrentCommand) }
        guard current.commandID == expectedCommandID else {
            return .rejected(.staleExpectedCommand)
        }
        guard response.command_id == expectedCommandID else {
            return .rejected(.responseCommandMismatch)
        }
        guard CommandLifecycle.isKnown(response.state) else {
            return .rejected(.invalidResponse)
        }
        guard let version = response.version, version >= 0 else {
            return .rejected(.missingVersion)
        }
        if let currentVersion = current.backendVersion {
            if version < currentVersion { return .rejected(.lowerVersion) }
            if version == currentVersion { return .idempotent }
        }

        let confirmation = pendingConfirmation(from: response)
        if current.phase == .submitting,
           response.state == "awaiting_confirmation",
           confirmation == nil
        {
            // A POST response for a protected command must carry the one-time
            // token. Keep the journaled envelope so cold-start reconciliation
            // can replay the same idempotent request and rotate the token.
            return .rejected(.invalidResponse)
        }
        let terminal = CommandLifecycle.isTerminal(response.state)
        let next = ActiveCommandCheckpoint(
            phase: terminal ? .terminalPendingPresentation : .acknowledged,
            commandID: current.commandID,
            backendState: response.state,
            backendVersion: version,
            envelope: nil,
            validatedPresentation: response.presentation?.validated(for: response.state),
            pendingConfirmation: response.state == "awaiting_confirmation"
                ? confirmation
                : nil,
            lastPresentedVersion: current.lastPresentedVersion,
            lastAnnouncedVersion: current.lastAnnouncedVersion,
            backendOrigin: current.backendOrigin,
            ownerUserID: current.ownerUserID,
            createdAt: current.createdAt
        )
        guard next.isStructurallyValid else { return .rejected(.invalidResponse) }
        return .replace(next)
    }

    static func confirmationReplayEnvelope(
        response: CommandResponse,
        expectedCommandID: String,
        current: ActiveCommandCheckpoint?
    ) -> CommandEnvelope? {
        guard let current,
              current.commandID == expectedCommandID,
              current.phase == .submitting,
              response.command_id == expectedCommandID,
              response.state == "awaiting_confirmation",
              response.confirmation_token == nil,
              response.action?.confirm_required == true,
              let envelope = current.envelope,
              envelope.commandID == expectedCommandID
        else { return nil }
        return envelope
    }

    static func pendingConfirmation(from response: CommandResponse) -> PendingCommandConfirmation? {
        guard response.state == "awaiting_confirmation",
              let action = response.action,
              action.confirm_required,
              let token = response.confirmation_token
        else { return nil }
        let confirmation = PendingCommandConfirmation(
            command_id: response.command_id,
            confirmation_token: token,
            title: action.title,
            risk: action.risk,
            confirm_required: action.confirm_required,
            reversible: action.reversible
        )
        return confirmation.isStructurallyValid ? confirmation : nil
    }

    static func handleNotFound(
        expectedCommandID: String,
        current: ActiveCommandCheckpoint?
    ) -> NotFoundResult {
        guard let current, current.commandID == expectedCommandID else { return .stale }
        guard current.phase == .submitting, let envelope = current.envelope else {
            return .unresolved
        }
        return .replay(envelope)
    }
}

/// Privacy-safe command status. Text and speech come from a validated server
/// presentation only; otherwise the UI uses a generic state label and TTS is
/// silent. Local transcripts, model prose, arguments, and results are ignored.
struct BackendCommandPresentation: Equatable {
    let commandID: String
    let version: Int
    let state: String
    let title: String
    let message: String
    let voiceScript: String?
    let isTerminal: Bool
    let isServerValidated: Bool

    init(response: CommandResponse) {
        self.init(
            commandID: response.command_id,
            version: response.version ?? 0,
            state: response.state,
            serverPresentation: response.presentation?.validated(for: response.state)
        )
    }

    init?(checkpoint: ActiveCommandCheckpoint) {
        if checkpoint.phase == .submitting,
           checkpoint.backendState == nil,
           checkpoint.backendVersion == nil
        {
            self.init(
                commandID: checkpoint.commandID,
                version: -1,
                state: "submitting",
                serverPresentation: nil
            )
            return
        }
        guard let state = checkpoint.backendState,
              let version = checkpoint.backendVersion
        else { return nil }
        self.init(
            commandID: checkpoint.commandID,
            version: version,
            state: state,
            serverPresentation: checkpoint.validatedPresentation
        )
    }

    private init(
        commandID: String,
        version: Int,
        state: String,
        serverPresentation: CommandPresentation?
    ) {
        self.commandID = commandID
        self.version = version
        self.state = state
        title = "Command update"
        isTerminal = CommandLifecycle.isTerminal(state)
        if let serverPresentation {
            message = serverPresentation.display_text
            voiceScript = serverPresentation.voice_script
            isServerValidated = true
        } else {
            message = Self.genericMessage(for: state)
            voiceScript = nil
            isServerValidated = false
        }
    }

    private static func genericMessage(for state: String) -> String {
        switch state {
        case "submitting": return "Sending command. Waiting for the backend to confirm receipt."
        case "pending", "validated", "queued": return "Command status: queued."
        case "awaiting_confirmation": return "Command status: awaiting confirmation."
        case "running": return "Command status: running."
        case "retryable": return "Command status: retry pending."
        case "unknown": return "Command status is being reconciled."
        case "succeeded": return "Command status: succeeded."
        case "failed": return "Command status: failed."
        case "expired": return "Command status: expired."
        case "cancelled": return "Command status: cancelled."
        default: return "Command status: \(state.isEmpty ? "unknown" : state)."
        }
    }
}

struct ActiveCommandApplication {
    enum Outcome: Equatable {
        case applied
        case idempotent
    }

    let response: CommandResponse
    let outcome: Outcome
}

/// Coordinates the durable checkpoint and its only external side effect, TTS.
/// Every write happens before the corresponding POST or announcement.
@MainActor
final class ActiveCommandCheckpointCoordinator {
    private let store: SQLiteStore
    private let synthesizer: VoiceSynthesizing
    private let isSpeechAllowed: () -> Bool

    private(set) var checkpoint: ActiveCommandCheckpoint?
    private(set) var presentation: BackendCommandPresentation?
    private(set) var lastSpoken: String?

    init(
        store: SQLiteStore,
        synthesizer: VoiceSynthesizing,
        isSpeechAllowed: @escaping () -> Bool = { true }
    ) {
        self.store = store
        self.synthesizer = synthesizer
        self.isSpeechAllowed = isSpeechAllowed
    }

    var commandIDForReconciliation: String? {
        guard let checkpoint,
              checkpoint.phase == .submitting || checkpoint.phase == .acknowledged
        else { return nil }
        return checkpoint.commandID
    }

    var durablePendingConfirmation: PendingCommandConfirmation? {
        checkpoint?.pendingConfirmation
    }

    @discardableResult
    func restore(scope: ActiveCommandScope) throws -> BackendCommandPresentation? {
        guard let stored = store.loadActiveCommandCheckpoint() else {
            checkpoint = nil
            presentation = nil
            return nil
        }
        guard stored.backendOrigin == scope.backendOrigin,
              stored.ownerUserID == scope.ownerUserID
        else {
            guard store.clearActiveCommandCheckpoint() else {
                throw ActiveCommandCheckpointError.persistenceFailed
            }
            checkpoint = nil
            presentation = nil
            return nil
        }
        if deliveryObligationsAreSatisfied(for: stored) {
            guard store.clearActiveCommandCheckpoint() else {
                throw ActiveCommandCheckpointError.persistenceFailed
            }
            checkpoint = nil
            presentation = nil
            return nil
        }
        checkpoint = stored
        presentation = BackendCommandPresentation(checkpoint: stored)
        try announceIfNeeded()
        return presentation
    }

    func begin(
        envelope: CommandEnvelope,
        scope: ActiveCommandScope,
        createdAt: Date = Date()
    ) throws {
        let next = try ActiveCommandCheckpointReducer.start(
            current: checkpoint,
            envelope: envelope,
            scope: scope,
            createdAt: createdAt
        )
        guard store.saveActiveCommandCheckpoint(next) else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        checkpoint = next
        presentation = BackendCommandPresentation(checkpoint: next)
    }

    func submit(
        envelope: CommandEnvelope,
        scope: ActiveCommandScope,
        createdAt: Date = Date(),
        onBegan: () -> Void = {},
        post: (CommandEnvelope) async throws -> CommandResponse
    ) async throws -> ActiveCommandApplication {
        try begin(envelope: envelope, scope: scope, createdAt: createdAt)
        onBegan()
        let response = try await post(envelope)
        guard let application = try accept(
            response: response,
            expectedCommandID: envelope.commandID
        ) else {
            throw ActiveCommandCheckpointError.rejectedResponse(.staleExpectedCommand)
        }
        return application
    }

    /// Clears only a request that is known not to have reached backend
    /// acceptance. Ambiguous network/decoding failures must keep the envelope
    /// so reconciliation can safely GET or replay the same idempotent command.
    func abandonUnacknowledgedSubmission(expectedCommandID: String) throws {
        guard let checkpoint,
              checkpoint.commandID == expectedCommandID,
              checkpoint.phase == .submitting,
              checkpoint.backendState == nil,
              checkpoint.backendVersion == nil,
              checkpoint.envelope != nil
        else { return }
        guard store.clearActiveCommandCheckpoint() else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        discardInMemory()
    }

    func reconcileCurrent(
        get: (String) async throws -> CommandResponse,
        replay: (CommandEnvelope) async throws -> CommandResponse,
        definitelyRejected: (Error) -> Bool = { _ in false }
    ) async throws -> ActiveCommandApplication? {
        guard let expectedCommandID = commandIDForReconciliation else { return nil }
        do {
            let response = try await get(expectedCommandID)
            if let envelope = ActiveCommandCheckpointReducer.confirmationReplayEnvelope(
                response: response,
                expectedCommandID: expectedCommandID,
                current: checkpoint
            ) {
                let replayedResponse = try await replay(envelope)
                guard ActiveCommandCheckpointReducer.pendingConfirmation(from: replayedResponse) != nil else {
                    throw ActiveCommandCheckpointError.rejectedResponse(.invalidResponse)
                }
                return try acceptForReconciliation(
                    response: replayedResponse,
                    expectedCommandID: expectedCommandID
                )
            }
            return try acceptForReconciliation(
                response: response,
                expectedCommandID: expectedCommandID
            )
        } catch let APIClientError.badStatus(code, _, _) where code == 404 {
            switch ActiveCommandCheckpointReducer.handleNotFound(
                expectedCommandID: expectedCommandID,
                current: checkpoint
            ) {
            case let .replay(envelope):
                let response: CommandResponse
                do {
                    response = try await replay(envelope)
                } catch {
                    guard definitelyRejected(error) else { throw error }
                    try abandonUnacknowledgedSubmission(expectedCommandID: expectedCommandID)
                    return nil
                }
                return try acceptForReconciliation(
                    response: response,
                    expectedCommandID: expectedCommandID
                )
            case .stale:
                return nil
            case .unresolved:
                throw ActiveCommandCheckpointError.currentCommandMissing(expectedCommandID)
            }
        }
    }

    func accept(
        response: CommandResponse,
        expectedCommandID: String
    ) throws -> ActiveCommandApplication? {
        switch ActiveCommandCheckpointReducer.apply(
            response: response,
            expectedCommandID: expectedCommandID,
            current: checkpoint
        ) {
        case let .replace(next):
            guard store.saveActiveCommandCheckpoint(next) else {
                throw ActiveCommandCheckpointError.persistenceFailed
            }
            checkpoint = next
            presentation = BackendCommandPresentation(checkpoint: next)
            try announceIfNeeded()
            return ActiveCommandApplication(response: response, outcome: .applied)
        case .idempotent:
            try announceIfNeeded()
            return ActiveCommandApplication(response: response, outcome: .idempotent)
        case let .rejected(reason):
            if reason == .staleExpectedCommand || reason == .noCurrentCommand {
                return nil
            }
            throw ActiveCommandCheckpointError.rejectedResponse(reason)
        }
    }

    /// Records the UI obligation independently from speech. A background
    /// terminal result remains durable until any deferred voice script has
    /// also been announced.
    func markPresented(commandID: String, version: Int) throws {
        guard var checkpoint,
              checkpoint.commandID == commandID,
              checkpoint.backendVersion == version,
              checkpoint.phase == .terminalPendingPresentation
        else { return }
        if checkpoint.lastPresentedVersion == version {
            // The durable row may already have been cleared after speech. Do
            // not recreate it when SwiftUI mounts the same presentation again.
            try clearDurableCheckpointIfDelivered()
            return
        }
        checkpoint.lastPresentedVersion = version
        guard checkpoint.isStructurallyValid,
              store.saveActiveCommandCheckpoint(checkpoint)
        else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        self.checkpoint = checkpoint
        try clearDurableCheckpointIfDelivered()
    }

    func clearForScopeChange() throws {
        guard store.clearActiveCommandCheckpoint() else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        discardInMemory()
    }

    func discardInMemory() {
        // Backend voice output may still be in progress when the user logs out,
        // changes API/account scope, refreshes the model, or starts a new voice
        // capture. Stop it before dropping the ownership checkpoint so private
        // text cannot continue across that boundary.
        synthesizer.stop()
        checkpoint = nil
        presentation = nil
        lastSpoken = nil
    }

    /// A silent background reconciliation may persist a newer canonical
    /// presentation without speaking it. The foreground lifecycle calls this
    /// method so that exact durable version is announced once, after the app
    /// becomes active.
    func announceDeferredIfNeeded() throws {
        try announceIfNeeded()
    }

    private func acceptForReconciliation(
        response: CommandResponse,
        expectedCommandID: String
    ) throws -> ActiveCommandApplication? {
        do {
            return try accept(response: response, expectedCommandID: expectedCommandID)
        } catch let error as ActiveCommandCheckpointError {
            if error == .rejectedResponse(.staleExpectedCommand)
                || error == .rejectedResponse(.noCurrentCommand)
            {
                return nil
            }
            throw error
        }
    }

    private func announceIfNeeded() throws {
        guard var checkpoint,
              let presentation,
              let voiceScript = presentation.voiceScript,
              checkpoint.lastAnnouncedVersion != presentation.version,
              isSpeechAllowed()
        else { return }
        checkpoint.lastAnnouncedVersion = presentation.version
        guard checkpoint.isStructurallyValid,
              store.saveActiveCommandCheckpoint(checkpoint)
        else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        self.checkpoint = checkpoint
        synthesizer.stop()
        synthesizer.speak(voiceScript)
        lastSpoken = voiceScript
        try clearDurableCheckpointIfDelivered()
    }

    private func clearDurableCheckpointIfDelivered() throws {
        guard let checkpoint,
              deliveryObligationsAreSatisfied(for: checkpoint)
        else { return }
        guard store.clearActiveCommandCheckpoint() else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
    }

    private func deliveryObligationsAreSatisfied(
        for checkpoint: ActiveCommandCheckpoint
    ) -> Bool {
        guard checkpoint.phase == .terminalPendingPresentation,
              let version = checkpoint.backendVersion,
              checkpoint.lastPresentedVersion == version
        else { return false }
        return checkpoint.validatedPresentation?.voice_script == nil
            || checkpoint.lastAnnouncedVersion == version
    }
}

import Foundation
import Security

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

protocol PendingAskRequestStoring: AnyObject {
    func load() -> PendingAskRequestIdentity?
    @discardableResult
    func save(_ request: PendingAskRequestIdentity) -> Bool
    @discardableResult
    func clear() -> Bool
}

/// Stores the sensitive replay payload in the OS-encrypted Keychain. SQLite
/// keeps only a SHA-256 fingerprint, so transcript and listener fence values
/// never enter the local database or diagnostic output.
final class KeychainPendingAskRequestStore: PendingAskRequestStoring {
    private static let service = "\(Bundle.main.bundleIdentifier ?? "hk.knockknock.app").pending-ask"
    private static let account = "pending-ask-request-v1"

    func load() -> PendingAskRequestIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let request = try? JSONDecoder().decode(
                  PendingAskRequestIdentity.self,
                  from: data
              ),
              request.isStructurallyValid
        else { return nil }
        return request
    }

    @discardableResult
    func save(_ request: PendingAskRequestIdentity) -> Bool {
        guard request.isStructurallyValid,
              let data = try? JSONEncoder().encode(request)
        else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item.merge(attributes) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

enum ActiveCommandCheckpointError: LocalizedError, Equatable {
    case commandInProgress(String)
    case persistenceFailed
    case rejectedResponse(ActiveCommandCheckpointReducer.Rejection)
    case currentCommandMissing(String)
    case pendingAskRecoveryUnavailable
    case sensitiveCleanupPending

    var errorDescription: String? {
        switch self {
        case .commandInProgress:
            return "A command is still open. If it is queued, tap Cancel, then speak again."
        case .persistenceFailed:
            return "The voice command could not be saved safely, so it was not sent."
        case let .rejectedResponse(reason):
            return "The backend command response was rejected (\(reason.description))."
        case let .currentCommandMissing(commandID):
            return "Command \(commandID) is missing from the backend and cannot be reconciled safely."
        case .pendingAskRecoveryUnavailable:
            return "An unfinished Ask could not be recovered safely. Please ask again."
        case .sensitiveCleanupPending:
            return "Sensitive Ask cleanup is still pending. Retry when the device is unlocked."
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
        case divergentEqualVersion
        case invalidResponse

        var description: String {
            switch self {
            case .noCurrentCommand: return "no current command"
            case .staleExpectedCommand: return "stale command id"
            case .responseCommandMismatch: return "wrong command id"
            case .missingVersion: return "missing command version"
            case .lowerVersion: return "lower command version"
            case .divergentEqualVersion: return "divergent equal command version"
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
        let nextPhase: ActiveCommandCheckpoint.Phase = terminal
            ? .terminalPendingPresentation
            : .acknowledged
        let validatedPresentation = response.presentation?.validated(for: response.state)
        let nextConfirmation = response.state == "awaiting_confirmation"
            ? confirmation
            : nil
        if let currentVersion = current.backendVersion {
            if version < currentVersion { return .rejected(.lowerVersion) }
            if version == currentVersion {
                let sameLifecycle = current.phase == nextPhase
                    && current.backendState == response.state
                    && current.validatedPresentation == validatedPresentation
                if sameLifecycle, current.pendingConfirmation == nextConfirmation {
                    return .idempotent
                }
                // GET at the same version omits the one-time confirmation
                // token. Keep the journaled POST token instead of treating
                // that expected omission as a divergent snapshot.
                if sameLifecycle,
                   nextConfirmation == nil,
                   current.pendingConfirmation != nil
                {
                    return .idempotent
                }
                return .rejected(.divergentEqualVersion)
            }
        }

        let next = ActiveCommandCheckpoint(
            phase: nextPhase,
            commandID: current.commandID,
            backendState: response.state,
            backendVersion: version,
            envelope: nil,
            validatedPresentation: validatedPresentation,
            pendingConfirmation: nextConfirmation,
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
    let isCancellable: Bool
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
        isCancellable = CommandLifecycle.canCancel(state)
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

    var nextStepHint: String? {
        guard isCancellable else { return nil }
        switch state {
        case "awaiting_confirmation":
            return "Confirm this command to continue."
        default:
            return "Cancel to speak another command."
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
/// A phone Ask answer claims its durable at-most-once speech right before audio
/// starts. Completion callbacks are advisory and remain fenced to that owner.
@MainActor
final class ActiveCommandCheckpointCoordinator {
    private enum AnnouncementOwner: Equatable {
        case command(commandID: String, version: Int)
        case ask(clientTurnID: String, askID: String, sequence: Int)
    }

    private struct ActiveAnnouncement: Equatable {
        let id: UInt64
        let owner: AnnouncementOwner
        let voiceScript: String
    }

    private let store: SQLiteStore
    private let synthesizer: VoiceSynthesizing
    private let isSpeechAllowed: () -> Bool
    private let pendingAskRequestStore: PendingAskRequestStoring

    private(set) var checkpoint: ActiveCommandCheckpoint?
    private(set) var presentation: BackendCommandPresentation?
    private(set) var pendingAskCheckpoint: PendingAskCheckpoint?
    private(set) var lastSpoken: String?
    var onAnnouncementStateChange: ((ActiveCommandCheckpointError?) -> Void)?

    private var nextAnnouncementID: UInt64 = 0
    private var activeAnnouncement: ActiveAnnouncement?
    private var lastCompletedAskID: String?

    init(
        store: SQLiteStore,
        synthesizer: VoiceSynthesizing,
        pendingAskRequestStore: PendingAskRequestStoring = KeychainPendingAskRequestStore(),
        isSpeechAllowed: @escaping () -> Bool = { true }
    ) {
        self.store = store
        self.synthesizer = synthesizer
        self.pendingAskRequestStore = pendingAskRequestStore
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

    var pendingAskSessionIDForReconciliation: String? {
        guard pendingAskCheckpoint?.phase == .awaitingAnswer else { return nil }
        return pendingAskCheckpoint?.sessionID
    }

    var hasPendingAskSelection: Bool {
        pendingAskCheckpoint?.phase == .selected
    }

    var hasPendingSensitiveCleanup: Bool {
        store.loadPendingAskSensitiveCleanupCheckpoint() != nil
    }

    func hasCanonicalAnswer(for response: PhoneAskResponse) -> Bool {
        if lastCompletedAskID == response.ask_id {
            return true
        }
        guard let pendingAskCheckpoint,
              pendingAskCheckpoint.askID == response.ask_id,
              pendingAskCheckpoint.sessionID == response.session_id
        else { return false }
        return pendingAskCheckpoint.phase == .answerPendingAnnouncement
            || pendingAskCheckpoint.phase == .answerPresented
    }

    @discardableResult
    func restore(scope: ActiveCommandScope) throws -> BackendCommandPresentation? {
        if let stored = store.loadActiveCommandCheckpoint() {
            if stored.backendOrigin == scope.backendOrigin,
               stored.ownerUserID == scope.ownerUserID
            {
                if deliveryObligationsAreSatisfied(for: stored) {
                    guard store.clearActiveCommandCheckpoint() else {
                        throw ActiveCommandCheckpointError.persistenceFailed
                    }
                    checkpoint = nil
                    presentation = nil
                } else {
                    checkpoint = stored
                    presentation = BackendCommandPresentation(checkpoint: stored)
                }
            } else {
                guard store.clearActiveCommandCheckpoint() else {
                    throw ActiveCommandCheckpointError.persistenceFailed
                }
                checkpoint = nil
                presentation = nil
            }
        } else {
            checkpoint = nil
            presentation = nil
        }

        let cleanupFinished = try retryPendingSensitiveCleanup()
        if !cleanupFinished,
           store.loadPendingAskSensitiveCleanupCheckpoint()?.clearPendingAskCheckpoint == true
        {
            pendingAskCheckpoint = store.loadPendingAskCheckpoint()
            throw ActiveCommandCheckpointError.sensitiveCleanupPending
        }

        if let storedAsk = store.loadPendingAskCheckpoint() {
            if storedAsk.backendOrigin == scope.backendOrigin,
               storedAsk.ownerUserID == scope.ownerUserID
            {
                pendingAskCheckpoint = storedAsk
                switch storedAsk.phase {
                case .selected:
                    if validatedPendingAskRequest(for: storedAsk) == nil {
                        if let orphan = pendingAskRequestStore.load() {
                            guard try requestSensitiveCleanup(
                                fingerprint: orphan.fingerprint,
                                clearPendingAskCheckpoint: true
                            ) else {
                                throw ActiveCommandCheckpointError.sensitiveCleanupPending
                            }
                        } else {
                            guard store.clearPendingAskCheckpoint() else {
                                throw ActiveCommandCheckpointError.persistenceFailed
                            }
                            pendingAskCheckpoint = nil
                        }
                        throw ActiveCommandCheckpointError.pendingAskRecoveryUnavailable
                    }
                case .awaitingAnswer:
                    try retryAcceptedSensitiveCleanup(for: storedAsk)
                case .answerPendingAnnouncement:
                    if askDeliveryObligationIsSatisfied(for: storedAsk) {
                        let presented = try answerPresentedCheckpoint(from: storedAsk)
                        pendingAskCheckpoint = presented
                        lastCompletedAskID = presented.askID
                    }
                    try retryAcceptedSensitiveCleanup(
                        for: pendingAskCheckpoint ?? storedAsk
                    )
                case .answerPresented:
                    lastCompletedAskID = storedAsk.askID
                    try retryAcceptedSensitiveCleanup(for: storedAsk)
                }
            } else {
                pendingAskCheckpoint = storedAsk
                guard try requestSensitiveCleanup(
                    for: storedAsk,
                    clearPendingAskCheckpoint: true
                ) else {
                    throw ActiveCommandCheckpointError.sensitiveCleanupPending
                }
                pendingAskCheckpoint = nil
            }
        } else {
            pendingAskCheckpoint = nil
            if let orphan = pendingAskRequestStore.load() {
                guard try requestSensitiveCleanup(
                    fingerprint: orphan.fingerprint,
                    clearPendingAskCheckpoint: false
                ) else {
                    throw ActiveCommandCheckpointError.sensitiveCleanupPending
                }
            }
        }

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

    /// Journals the newest selected Ask before its POST. Repeating the same
    /// client turn is idempotent so an ambiguous delivery retry keeps one
    /// durable identity; a newer client turn supersedes every older answer.
    @discardableResult
    func beginPendingAsk(
        request: PendingAskRequestIdentity,
        scope: ActiveCommandScope,
        createdAt: Date = Date()
    ) throws -> PendingAskBeginOutcome {
        guard request.isStructurallyValid else {
            throw ActiveCommandCheckpointError.pendingAskRecoveryUnavailable
        }
        if let current = pendingAskCheckpoint,
           current.clientTurnID == request.clientTurnID
        {
            guard current.agentID == request.agentID,
                  current.agentLabel == request.agentLabel,
                  current.requestFingerprint == request.fingerprint,
                  current.backendOrigin == scope.backendOrigin,
                  current.ownerUserID == scope.ownerUserID
            else {
                throw ActiveCommandCheckpointError.pendingAskRecoveryUnavailable
            }
            switch current.phase {
            case .selected:
                guard let storedRequest = validatedPendingAskRequest(for: current),
                      storedRequest.hasSameFrozenIdentity(as: request)
                else {
                    throw ActiveCommandCheckpointError.pendingAskRecoveryUnavailable
                }
                return .selected(storedRequest)
            case .awaitingAnswer:
                return .alreadyAccepted(try acceptedResponse(from: current))
            case .answerPendingAnnouncement, .answerPresented:
                return .alreadyReconciled
            }
        }

        guard try retryPendingSensitiveCleanup() else {
            throw ActiveCommandCheckpointError.sensitiveCleanupPending
        }
        if let current = pendingAskCheckpoint {
            guard try requestSensitiveCleanup(
                for: current,
                clearPendingAskCheckpoint: true
            ) else {
                throw ActiveCommandCheckpointError.sensitiveCleanupPending
            }
        }
        let next = PendingAskCheckpoint(
            phase: .selected,
            clientTurnID: request.clientTurnID,
            agentID: request.agentID,
            agentLabel: request.agentLabel,
            requestFingerprint: request.fingerprint,
            askID: nil,
            sessionID: nil,
            initialTurnSequence: nil,
            answerSequence: nil,
            answerText: nil,
            lastAnnouncedSequence: nil,
            backendOrigin: scope.backendOrigin,
            ownerUserID: scope.ownerUserID,
            createdAt: createdAt
        )
        let previousRequest = pendingAskRequestStore.load()
        guard next.isStructurallyValid,
              pendingAskRequestStore.save(request)
        else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        guard store.savePendingAskCheckpoint(next) else {
            if let previousRequest {
                _ = pendingAskRequestStore.save(previousRequest)
            } else {
                _ = pendingAskRequestStore.clear()
            }
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        if let activeAnnouncement,
           case .ask = activeAnnouncement.owner
        {
            self.activeAnnouncement = nil
            synthesizer.stop()
        }
        pendingAskCheckpoint = next
        lastCompletedAskID = nil
        return .selected(request)
    }

    @discardableResult
    func acceptAskSubmission(
        _ response: PhoneAskResponse,
        expectedClientTurnID: String
    ) throws -> Bool {
        guard let current = pendingAskCheckpoint,
              current.clientTurnID == expectedClientTurnID
        else { return false }
        try response.validate(expectedAgentID: current.agentID)
        guard let sessionID = response.session_id,
              let turnSequence = response.turn_sequence
        else { throw PhoneAskResponseValidationError.checkpointChanged }
        let askID = response.ask_id
        if current.phase != .selected {
            return current.askID == askID
                && current.sessionID == sessionID
                && current.initialTurnSequence == turnSequence
        }
        let next = PendingAskCheckpoint(
            phase: .awaitingAnswer,
            clientTurnID: current.clientTurnID,
            agentID: current.agentID,
            agentLabel: current.agentLabel,
            requestFingerprint: current.requestFingerprint,
            askID: askID,
            sessionID: sessionID,
            initialTurnSequence: turnSequence,
            answerSequence: nil,
            answerText: nil,
            lastAnnouncedSequence: nil,
            backendOrigin: current.backendOrigin,
            ownerUserID: current.ownerUserID,
            createdAt: current.createdAt
        )
        guard next.isStructurallyValid,
              store.savePendingAskCheckpoint(next)
        else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        pendingAskCheckpoint = next
        do {
            _ = try requestSensitiveCleanup(
                for: next,
                clearPendingAskCheckpoint: false
            )
        } catch let error as ActiveCommandCheckpointError {
            onAnnouncementStateChange?(error)
        } catch {
            onAnnouncementStateChange?(.persistenceFailed)
        }
        return true
    }

    func prepareSessionlessPendingAskRetry(
        expectedClientTurnID: String
    ) throws -> PendingAskRequestIdentity {
        guard let current = pendingAskCheckpoint,
              current.phase == .selected,
              current.clientTurnID == expectedClientTurnID,
              let request = validatedPendingAskRequest(for: current)
        else {
            throw ActiveCommandCheckpointError.pendingAskRecoveryUnavailable
        }
        guard request.request.session_id != nil else { return request }
        let sessionless = request.replacingSessionID(nil)
        guard sessionless.fingerprint == current.requestFingerprint,
              pendingAskRequestStore.save(sessionless)
        else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        return sessionless
    }

    func reconcileSelectedPendingAsk(
        scope: ActiveCommandScope,
        replay: (PendingAskRequestIdentity) async throws -> PhoneAskResponse,
        definitelyRejected: (Error) -> Bool
    ) async throws -> PhoneAskResponse? {
        guard let current = pendingAskCheckpoint,
              current.phase == .selected
        else { return nil }
        guard current.backendOrigin == scope.backendOrigin,
              current.ownerUserID == scope.ownerUserID,
              let request = validatedPendingAskRequest(for: current)
        else {
            throw ActiveCommandCheckpointError.pendingAskRecoveryUnavailable
        }
        do {
            let response = try await replay(request)
            guard pendingAskCheckpoint?.clientTurnID == current.clientTurnID else {
                return nil
            }
            guard try acceptAskSubmission(
                response,
                expectedClientTurnID: current.clientTurnID
            ) else {
                return nil
            }
            return response
        } catch {
            if definitelyRejected(error) {
                try abandonPendingAskSelection(
                    expectedClientTurnID: current.clientTurnID
                )
            }
            throw error
        }
    }

    func abandonPendingAskSelection(expectedClientTurnID: String) throws {
        guard let pendingAskCheckpoint,
              pendingAskCheckpoint.clientTurnID == expectedClientTurnID,
              pendingAskCheckpoint.phase == .selected
        else { return }
        guard try requestSensitiveCleanup(
            for: pendingAskCheckpoint,
            clearPendingAskCheckpoint: true
        ) else {
            throw ActiveCommandCheckpointError.sensitiveCleanupPending
        }
    }

    /// Accepts only one canonical agent message for the currently selected
    /// Ask. Sequence is the backend version and Ask metadata prevents an older
    /// answer from the same conversation speaking over a newer turn.
    @discardableResult
    func acceptPendingAskAnswer(_ message: SessionMessage) throws -> Bool {
        guard let current = pendingAskCheckpoint,
              current.phase == .awaitingAnswer
                  || current.phase == .answerPendingAnnouncement,
              let askID = current.askID,
              let sessionID = current.sessionID,
              let initialTurnSequence = current.initialTurnSequence,
              message.session_id == sessionID,
              message.role == "agent",
              message.sequence > initialTurnSequence,
              case let .string(messageAskID)? = message.metadata["ask_id"],
              messageAskID == askID
        else { return false }
        if case let .string(messageClientTurnID)? = message.metadata["client_turn_id"],
           messageClientTurnID != current.clientTurnID
        {
            return false
        }
        if current.phase == .answerPendingAnnouncement {
            try announceIfNeeded()
            return false
        }
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let next = PendingAskCheckpoint(
            phase: .answerPendingAnnouncement,
            clientTurnID: current.clientTurnID,
            agentID: current.agentID,
            agentLabel: current.agentLabel,
            requestFingerprint: current.requestFingerprint,
            askID: askID,
            sessionID: sessionID,
            initialTurnSequence: initialTurnSequence,
            answerSequence: message.sequence,
            answerText: text,
            lastAnnouncedSequence: nil,
            backendOrigin: current.backendOrigin,
            ownerUserID: current.ownerUserID,
            createdAt: current.createdAt
        )
        guard next.isStructurallyValid,
              store.savePendingAskCheckpoint(next)
        else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        pendingAskCheckpoint = next
        try announceIfNeeded()
        return true
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
        guard try retryPendingSensitiveCleanup() else {
            throw ActiveCommandCheckpointError.sensitiveCleanupPending
        }
        if let pending = pendingAskCheckpoint ?? store.loadPendingAskCheckpoint() {
            pendingAskCheckpoint = pending
            guard try requestSensitiveCleanup(
                for: pending,
                clearPendingAskCheckpoint: true
            ) else {
                throw ActiveCommandCheckpointError.sensitiveCleanupPending
            }
        } else if let orphan = pendingAskRequestStore.load() {
            guard try requestSensitiveCleanup(
                fingerprint: orphan.fingerprint,
                clearPendingAskCheckpoint: false
            ) else {
                throw ActiveCommandCheckpointError.sensitiveCleanupPending
            }
        }
        guard store.clearActiveCommandCheckpoint(),
              store.clearPendingAskCheckpoint(),
              store.clearPendingAskSensitiveCleanupCheckpoint()
        else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        discardInMemory()
    }

    func discardInMemory() {
        // Backend voice output may still be in progress when the user logs out,
        // changes API/account scope, refreshes the model, or starts a new voice
        // capture. Stop it before dropping the ownership checkpoint so private
        // text cannot continue across that boundary.
        activeAnnouncement = nil
        synthesizer.stop()
        checkpoint = nil
        presentation = nil
        pendingAskCheckpoint = nil
        lastCompletedAskID = nil
        lastSpoken = nil
    }

    /// A silent background reconciliation may persist a newer canonical
    /// presentation without speaking it. The foreground lifecycle calls this
    /// method so that exact durable version is announced once, after the app
    /// becomes active.
    func announceDeferredIfNeeded() throws {
        _ = try retryPendingSensitiveCleanup()
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
        guard activeAnnouncement == nil, isSpeechAllowed() else { return }
        if let checkpoint,
           let presentation,
           let voiceScript = presentation.voiceScript,
           checkpoint.lastAnnouncedVersion != presentation.version
        {
            startAnnouncement(
                owner: .command(
                    commandID: presentation.commandID,
                    version: presentation.version
                ),
                voiceScript: voiceScript
            )
            return
        }
        if let pendingAskCheckpoint,
           pendingAskCheckpoint.phase == .answerPendingAnnouncement,
           let askID = pendingAskCheckpoint.askID,
           let sequence = pendingAskCheckpoint.answerSequence,
           let answerText = pendingAskCheckpoint.answerText,
           pendingAskCheckpoint.lastAnnouncedSequence != sequence
        {
            var claimed = pendingAskCheckpoint
            claimed.lastAnnouncedSequence = sequence
            let presented = try answerPresentedCheckpoint(from: claimed)
            self.pendingAskCheckpoint = presented
            lastCompletedAskID = askID
            startAnnouncement(
                owner: .ask(
                    clientTurnID: pendingAskCheckpoint.clientTurnID,
                    askID: askID,
                    sequence: sequence
                ),
                voiceScript: answerText
            )
        }
    }

    private func startAnnouncement(
        owner: AnnouncementOwner,
        voiceScript: String
    ) {
        activeAnnouncement = nil
        synthesizer.stop()
        nextAnnouncementID += 1
        let announcement = ActiveAnnouncement(
            id: nextAnnouncementID,
            owner: owner,
            voiceScript: voiceScript
        )
        activeAnnouncement = announcement
        synthesizer.speak(voiceScript) { [weak self] result in
            // Some synthesizers complete inline. Always leave their speak stack
            // before mutating durable ownership or draining the next announcement.
            // The weak capture and ActiveAnnouncement identity check make this
            // queued callback inert after cancellation, scope reset, or teardown.
            DispatchQueue.main.async { [weak self] in
                self?.completeAnnouncement(announcement, result: result)
            }
        }
    }

    private func completeAnnouncement(
        _ announcement: ActiveAnnouncement,
        result: VoiceSynthesisResult
    ) {
        guard activeAnnouncement == announcement else { return }
        activeAnnouncement = nil
        guard result == .finished else {
            drainCurrentAnnouncementAfterStaleCompletion()
            return
        }

        switch announcement.owner {
        case let .command(commandID, version):
            guard var checkpoint,
                  checkpoint.commandID == commandID,
                  checkpoint.backendVersion == version,
                  let presentation,
                  presentation.commandID == commandID,
                  presentation.version == version,
                  presentation.voiceScript == announcement.voiceScript,
                  checkpoint.lastAnnouncedVersion != version
            else {
                drainCurrentAnnouncementAfterStaleCompletion()
                return
            }
            checkpoint.lastAnnouncedVersion = version
            guard checkpoint.isStructurallyValid,
                  store.saveActiveCommandCheckpoint(checkpoint)
            else {
                onAnnouncementStateChange?(.persistenceFailed)
                return
            }
            self.checkpoint = checkpoint
            lastSpoken = announcement.voiceScript
            do {
                try clearDurableCheckpointIfDelivered()
                try announceIfNeeded()
                onAnnouncementStateChange?(nil)
            } catch let error as ActiveCommandCheckpointError {
                onAnnouncementStateChange?(error)
            } catch {
                onAnnouncementStateChange?(.persistenceFailed)
            }
        case let .ask(clientTurnID, askID, sequence):
            guard let pendingAskCheckpoint,
                  pendingAskCheckpoint.phase == .answerPresented,
                  pendingAskCheckpoint.clientTurnID == clientTurnID,
                  pendingAskCheckpoint.askID == askID,
                  pendingAskCheckpoint.answerSequence == sequence,
                  pendingAskCheckpoint.answerText == announcement.voiceScript,
                  pendingAskCheckpoint.lastAnnouncedSequence == sequence
            else {
                drainCurrentAnnouncementAfterStaleCompletion()
                return
            }
            lastSpoken = announcement.voiceScript
            lastCompletedAskID = askID
            do {
                let cleanupFinished = try requestSensitiveCleanup(
                    for: pendingAskCheckpoint,
                    clearPendingAskCheckpoint: false
                )
                try announceIfNeeded()
                onAnnouncementStateChange?(cleanupFinished ? nil : .sensitiveCleanupPending)
            } catch let error as ActiveCommandCheckpointError {
                onAnnouncementStateChange?(error)
            } catch {
                onAnnouncementStateChange?(.persistenceFailed)
            }
        }
    }

    private func drainCurrentAnnouncementAfterStaleCompletion() {
        do {
            try announceIfNeeded()
            onAnnouncementStateChange?(nil)
        } catch let error as ActiveCommandCheckpointError {
            onAnnouncementStateChange?(error)
        } catch {
            onAnnouncementStateChange?(.persistenceFailed)
        }
    }

    @discardableResult
    func retryPendingSensitiveCleanup() throws -> Bool {
        guard let cleanup = store.loadPendingAskSensitiveCleanupCheckpoint() else {
            return true
        }
        if let request = pendingAskRequestStore.load(),
           request.fingerprint != cleanup.requestFingerprint
        {
            throw ActiveCommandCheckpointError.pendingAskRecoveryUnavailable
        }
        guard pendingAskRequestStore.clear() else {
            onAnnouncementStateChange?(.sensitiveCleanupPending)
            return false
        }
        if cleanup.clearPendingAskCheckpoint {
            guard store.clearPendingAskCheckpoint() else {
                throw ActiveCommandCheckpointError.persistenceFailed
            }
            if pendingAskCheckpoint?.requestFingerprint == cleanup.requestFingerprint
                || pendingAskCheckpoint?.requestFingerprint == nil
            {
                pendingAskCheckpoint = nil
            }
        }
        guard store.clearPendingAskSensitiveCleanupCheckpoint() else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        onAnnouncementStateChange?(nil)
        return true
    }

    private func retryAcceptedSensitiveCleanup(
        for checkpoint: PendingAskCheckpoint
    ) throws {
        guard pendingAskRequestStore.load() != nil
                || store.loadPendingAskSensitiveCleanupCheckpoint() != nil
        else { return }
        _ = try requestSensitiveCleanup(
            for: checkpoint,
            clearPendingAskCheckpoint: false
        )
    }

    @discardableResult
    private func requestSensitiveCleanup(
        for checkpoint: PendingAskCheckpoint,
        clearPendingAskCheckpoint: Bool
    ) throws -> Bool {
        guard let fingerprint = checkpoint.requestFingerprint
                ?? pendingAskRequestStore.load()?.fingerprint
        else {
            if clearPendingAskCheckpoint {
                guard store.clearPendingAskCheckpoint() else {
                    throw ActiveCommandCheckpointError.persistenceFailed
                }
                pendingAskCheckpoint = nil
            }
            return true
        }
        return try requestSensitiveCleanup(
            fingerprint: fingerprint,
            clearPendingAskCheckpoint: clearPendingAskCheckpoint
        )
    }

    @discardableResult
    private func requestSensitiveCleanup(
        fingerprint: String,
        clearPendingAskCheckpoint: Bool
    ) throws -> Bool {
        if let existing = store.loadPendingAskSensitiveCleanupCheckpoint(),
           existing.requestFingerprint != fingerprint
        {
            guard try retryPendingSensitiveCleanup() else { return false }
        }
        let existing = store.loadPendingAskSensitiveCleanupCheckpoint()
        let cleanup = PendingAskSensitiveCleanupCheckpoint(
            requestFingerprint: fingerprint,
            clearPendingAskCheckpoint: clearPendingAskCheckpoint
                || existing?.clearPendingAskCheckpoint == true,
            createdAt: existing?.createdAt ?? Date()
        )
        guard cleanup.isStructurallyValid,
              store.savePendingAskSensitiveCleanupCheckpoint(cleanup)
        else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        return try retryPendingSensitiveCleanup()
    }

    private func acceptedResponse(
        from checkpoint: PendingAskCheckpoint
    ) throws -> PhoneAskResponse {
        guard let askID = checkpoint.askID,
              let sessionID = checkpoint.sessionID,
              let turnSequence = checkpoint.initialTurnSequence
        else {
            throw ActiveCommandCheckpointError.pendingAskRecoveryUnavailable
        }
        return PhoneAskResponse(
            ask_id: askID,
            agent_id: checkpoint.agentID,
            agent_label: checkpoint.agentLabel,
            session_id: sessionID,
            turn_sequence: turnSequence,
            status: "queued"
        )
    }

    private func answerPresentedCheckpoint(
        from checkpoint: PendingAskCheckpoint
    ) throws -> PendingAskCheckpoint {
        guard let answerSequence = checkpoint.answerSequence,
              checkpoint.lastAnnouncedSequence == answerSequence
        else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        let presented = PendingAskCheckpoint(
            phase: .answerPresented,
            clientTurnID: checkpoint.clientTurnID,
            agentID: checkpoint.agentID,
            agentLabel: checkpoint.agentLabel,
            requestFingerprint: checkpoint.requestFingerprint,
            askID: checkpoint.askID,
            sessionID: checkpoint.sessionID,
            initialTurnSequence: checkpoint.initialTurnSequence,
            answerSequence: answerSequence,
            answerText: checkpoint.answerText,
            lastAnnouncedSequence: answerSequence,
            backendOrigin: checkpoint.backendOrigin,
            ownerUserID: checkpoint.ownerUserID,
            createdAt: checkpoint.createdAt
        )
        guard presented.isStructurallyValid,
              store.savePendingAskCheckpoint(presented)
        else {
            throw ActiveCommandCheckpointError.persistenceFailed
        }
        return presented
    }

    private func validatedPendingAskRequest(
        for checkpoint: PendingAskCheckpoint
    ) -> PendingAskRequestIdentity? {
        guard checkpoint.phase == .selected,
              let fingerprint = checkpoint.requestFingerprint,
              let request = pendingAskRequestStore.load(),
              request.isStructurallyValid,
              request.fingerprint == fingerprint,
              request.clientTurnID == checkpoint.clientTurnID,
              request.agentID == checkpoint.agentID,
              request.agentLabel == checkpoint.agentLabel
        else { return nil }
        return request
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

    private func askDeliveryObligationIsSatisfied(
        for checkpoint: PendingAskCheckpoint
    ) -> Bool {
        checkpoint.phase == .answerPendingAnnouncement
            && checkpoint.answerSequence != nil
            && checkpoint.lastAnnouncedSequence == checkpoint.answerSequence
    }

    private func normalizedIdentifier(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == raw,
              !raw.isEmpty,
              raw.utf8.count <= 128
        else { return nil }
        return raw
    }
}

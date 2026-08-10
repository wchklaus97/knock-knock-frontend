import Foundation

struct AuthUser: Decodable, Equatable {
    let id: String
    let email: String?
}

struct AuthResponse: Decodable {
    /// Legacy names remain exposed to the current store while the wire
    /// contract uses access_token/user. The decoder accepts both shapes so an
    /// older Worker can be upgraded independently of the app.
    let user_id: String
    let token: String
    let refresh_token: String?
    let expires_in: Int?
    let access_token: String
    let user: AuthUser?

    private enum CodingKeys: String, CodingKey {
        case user_id, token, refresh_token, expires_in, access_token, user
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let canonicalToken = try container.decodeIfPresent(String.self, forKey: .access_token)
        let legacyToken = try container.decodeIfPresent(String.self, forKey: .token)
        guard let resolvedToken = canonicalToken ?? legacyToken, !resolvedToken.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.access_token,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Auth response did not contain an access token"
                )
            )
        }
        user = try container.decodeIfPresent(AuthUser.self, forKey: .user)
        if let user {
            user_id = user.id
        } else {
            user_id = try container.decode(String.self, forKey: .user_id)
        }
        token = resolvedToken
        access_token = canonicalToken ?? resolvedToken
        refresh_token = try container.decodeIfPresent(String.self, forKey: .refresh_token)
        expires_in = try container.decodeIfPresent(Int.self, forKey: .expires_in)
    }
}

struct Agent: Codable, Identifiable, Hashable {
    let agent_id: String
    let user_id: String
    let label: String
    let host_label: String?
    let created_at: String

    var id: String { agent_id }
    var displayLabel: String { label.isEmpty ? (host_label ?? agent_id) : label }
}

struct AgentsResponse: Decodable {
    let agents: [Agent]
}

/// The default realtime payload is intentionally small. It invalidates the
/// local snapshot; AppStore performs the authoritative REST reconciliation.
/// Other features can reuse the generic transport with their own Decodable
/// payload type later.
struct SessionInvalidation: Decodable {
    let id: String?
    let type: String?
    let session_id: String?
    let version: Int?
    let updated_at: String?
    let reason: String?
}

/// The bridge deliberately keeps facts unopinionated: agent skills can add
/// strings, numbers, flags, or nested values without requiring an iOS release.
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var displayValue: String {
        switch self {
        case let .string(value): return value
        case let .number(value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case let .bool(value): return value ? "Yes" : "No"
        case let .object(value): return "\(value.count) fields"
        case let .array(value): return "\(value.count) items"
        case .null: return "None"
        }
    }
}

struct PairingCodeResponse: Decodable {
    let code: String
    let expires_at: String
}

struct ActionDescriptor: Codable, Identifiable, Hashable {
    let action_key: String
    let title: String?
    let risk: String
    let confirm_required: Bool
    let payload: [String: JSONValue]?

    var id: String { action_key }
}

struct Session: Codable, Identifiable, Hashable {
    var id: String { session_id }
    let session_id: String
    let agent_id: String
    let skill_id: String
    let state: String
    let progress_status: String?
    let progress_message: String?
    let progress_percent: Double?
    let chat_id: String?
    let title: String?
    let summary_text: String?
    var voice_script: String?
    let available_actions: [String]?
    let available_action_descriptors: [ActionDescriptor]?
    let version: Int?
    var facts: [String: JSONValue]
    let expires_at: String
    let created_at: String
    let updated_at: String
    let archived_at: String?
    let deleted_at: String?
    let retention_expires_at: String?

    var needsUser: Bool { state == "needs_user" || state == "awaiting_confirm" }

    /// The registry descriptor is authoritative. Older Workers may only return
    /// action names; those names are intentionally not interpreted locally.
    /// Unknown policy is presented as unknown and requires an explicit server
    /// decision rather than being guessed from the action name.
    var actionDescriptors: [ActionDescriptor] {
        if let descriptors = available_action_descriptors, !descriptors.isEmpty {
            return descriptors
        }
        return (available_actions ?? []).map { key in
            ActionDescriptor(
                action_key: key,
                title: nil,
                risk: "unknown",
                confirm_required: true,
                payload: nil
            )
        }
    }

    mutating func mergeDetail(from detail: Session) {
        if facts.isEmpty { facts = detail.facts }
        if (voice_script ?? "").isEmpty { voice_script = detail.voice_script }
    }

    enum CodingKeys: String, CodingKey {
        case session_id, agent_id, skill_id, state
        case progress_status, progress_message, progress_percent, chat_id, title
        case summary_text, voice_script, available_actions, available_action_descriptors, version, facts
        case expires_at, created_at, updated_at, archived_at, deleted_at, retention_expires_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session_id = try c.decode(String.self, forKey: .session_id)
        agent_id = try c.decode(String.self, forKey: .agent_id)
        skill_id = try c.decode(String.self, forKey: .skill_id)
        state = try c.decode(String.self, forKey: .state)
        progress_status = try c.decodeIfPresent(String.self, forKey: .progress_status)
        progress_message = try c.decodeIfPresent(String.self, forKey: .progress_message)
        progress_percent = try c.decodeIfPresent(Double.self, forKey: .progress_percent)
        chat_id = try c.decodeIfPresent(String.self, forKey: .chat_id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        summary_text = try c.decodeIfPresent(String.self, forKey: .summary_text)
        voice_script = try c.decodeIfPresent(String.self, forKey: .voice_script)
        available_actions = try c.decodeIfPresent([String].self, forKey: .available_actions)
        available_action_descriptors = try c.decodeIfPresent(
            [ActionDescriptor].self,
            forKey: .available_action_descriptors
        )
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        facts = try c.decodeIfPresent([String: JSONValue].self, forKey: .facts) ?? [:]
        expires_at = try c.decodeIfPresent(String.self, forKey: .expires_at) ?? ""
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at) ?? ""
        updated_at = try c.decodeIfPresent(String.self, forKey: .updated_at) ?? ""
        archived_at = try c.decodeIfPresent(String.self, forKey: .archived_at)
        deleted_at = try c.decodeIfPresent(String.self, forKey: .deleted_at)
        retention_expires_at = try c.decodeIfPresent(String.self, forKey: .retention_expires_at)
    }
}

enum SessionFilter: String, CaseIterable, Identifiable, Hashable {
    case needsUser = "needs_user"
    case active
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsUser: return "Needs me"
        case .active: return "Active"
        case .all: return "All"
        }
    }
}

enum BridgeConnectionState: Equatable {
    case unknown
    case connected
    case unavailable

    var title: String {
        switch self {
        case .unknown: return "Connection status unknown"
        case .connected: return "Bridge connected"
        case .unavailable: return "Bridge unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .connected: return "checkmark.circle.fill"
        case .unavailable: return "wifi.exclamationmark"
        }
    }
}

extension Session {
    var isTerminal: Bool {
        ["succeeded", "failed", "cancelled", "expired"].contains(state)
    }

    /// Active excludes decisions waiting on the user because that state has
    /// its own high-priority inbox filter.
    var isActive: Bool {
        !needsUser && !isTerminal
    }

    var stateTitle: String {
        switch state {
        case "needs_user": return "Needs your decision"
        case "awaiting_confirm": return "Awaiting confirmation"
        case "started": return "Starting"
        case "running": return "Working"
        case "queued": return "Queued"
        case "claimed": return "Claimed by agent"
        case "succeeded": return "Succeeded"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        case "expired": return "Expired"
        default: return state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var stateSymbol: String {
        switch state {
        case "needs_user", "awaiting_confirm": return "hand.raised.fill"
        case "started", "running", "queued", "claimed": return "arrow.triangle.2.circlepath"
        case "succeeded": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "cancelled": return "xmark.circle"
        case "expired": return "clock.badge.xmark"
        default: return "circle.dotted"
        }
    }

    func matches(_ filter: SessionFilter) -> Bool {
        switch filter {
        case .needsUser: return needsUser
        case .active: return isActive
        case .all: return true
        }
    }
}

/// Search is intentionally client-side so the inbox stays useful while the
/// bridge is offline. Every non-empty query token must match the combined
/// agent/session text; this makes searches such as "codex deploy" predictable
/// instead of requiring the user to type one exact phrase.
struct SessionSearchMatcher {
    private let tokens: [String]

    init(query: String) {
        let normalized = Self.normalize(query)
        tokens = normalized
            .split { $0.isWhitespace || $0.isPunctuation }
            .map(String.init)
    }

    func matches(_ session: Session, agent: Agent?) -> Bool {
        guard !tokens.isEmpty else { return true }

        let factText = session.facts
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value.displayValue)" }
            .joined(separator: " ")
        let searchable = Self.normalize([
            session.title,
            session.skill_id,
            session.summary_text,
            session.voice_script,
            session.progress_message,
            session.session_id,
            session.state,
            session.stateTitle,
            session.available_actions?.joined(separator: " "),
            factText,
            agent?.displayLabel,
            agent?.label,
            agent?.host_label,
            agent?.agent_id,
        ].compactMap { $0 }.joined(separator: " "))

        return tokens.allSatisfy { searchable.contains($0) }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct SessionsResponse: Decodable {
    let sessions: [Session]
    let next_cursor: String?
    let has_more: Bool

    private enum CodingKeys: String, CodingKey {
        case sessions, next_cursor, has_more
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        next_cursor = try container.decodeIfPresent(String.self, forKey: .next_cursor)
        has_more = try container.decodeIfPresent(Bool.self, forKey: .has_more) ?? false
    }
}

struct DevPush: Codable, Identifiable {
    var id: String { push_id }
    let push_id: String
    let session_id: String
    let title: String
    let body: String
    let voice_script: String?
    let created_at: String
    let read_at: String?
    let dismissed_at: String?
}

struct DevPushesResponse: Decodable {
    let pushes: [DevPush]
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    let audit_id: String
    let action: String
    let session_id: String?
    let agent_id: String?
    let metadata: [String: JSONValue]
    let created_at: String

    var id: String { audit_id }

    var title: String {
        action
            .replacingOccurrences(of: "session.event.", with: "")
            .replacingOccurrences(of: "phone.", with: "Phone ")
            .replacingOccurrences(of: "agent.action_result.", with: "Agent result ")
            .replacingOccurrences(of: ".", with: " ")
            .capitalized
    }
}

struct HistoryResponse: Decodable {
    let entries: [HistoryEntry]
    let next_cursor: String?
    let has_more: Bool

    private enum CodingKeys: String, CodingKey {
        case entries, next_cursor, has_more
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([HistoryEntry].self, forKey: .entries) ?? []
        next_cursor = try container.decodeIfPresent(String.self, forKey: .next_cursor)
        has_more = try container.decodeIfPresent(Bool.self, forKey: .has_more) ?? false
    }
}

struct SessionMessage: Codable, Identifiable, Hashable {
    let message_id: String
    let session_id: String
    let role: String
    let content: String
    let metadata: [String: JSONValue]
    let command_id: String?
    let sequence: Int
    let created_at: String

    var id: String { message_id }
}

struct MessagePage: Decodable {
    let messages: [SessionMessage]
    let next_cursor: String?
    let has_more: Bool

    private enum CodingKeys: String, CodingKey {
        case messages, items, next_cursor, has_more
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decodeIfPresent([SessionMessage].self, forKey: .messages)
            ?? container.decodeIfPresent([SessionMessage].self, forKey: .items)
            ?? []
        next_cursor = try container.decodeIfPresent(String.self, forKey: .next_cursor)
        has_more = try container.decodeIfPresent(Bool.self, forKey: .has_more) ?? false
    }
}

struct RetrievalItem: Codable, Identifiable, Hashable {
    let retrieval_id: String
    let session_id: String
    let message_id: String?
    let title: String
    let url: String
    let snippet: String?
    let score: Double?
    let content_hash: String
    let created_at: String

    var id: String { retrieval_id }
}

struct SessionDetailResponse: Decodable {
    let session: Session
    let retrieval_items: [RetrievalItem]

    init(from decoder: Decoder) throws {
        session = try Session(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        retrieval_items = try container.decodeIfPresent([RetrievalItem].self, forKey: .retrieval_items) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case retrieval_items
    }
}

struct SearchResponse: Decodable {
    let query: String
    let sessions: [Session]
    let messages: [SessionMessage]
    let retrieval_items: [RetrievalItem]
}

struct PushReadAllResponse: Decodable {
    let updated: Int
    let read_at: String
}

struct DeletedSessionResponse: Decodable {
    let ok: Bool
    let session_id: String
    let deleted_at: String
}

struct SessionExportResponse: Decodable {
    let schema_version: Int
    let exported_at: String
    let session: Session
    let messages: [SessionMessage]
    let retrieval_items: [RetrievalItem]
    let truncated: Bool?
}

struct PhoneChange: Decodable {
    let cursor: String
    let entity_type: String
    let entity_id: String
    let session_id: String?
    let version: Int
    let deleted_at: String?
}

struct SyncResponse: Decodable {
    let cursor: String
    let changes: [PhoneChange]
    let has_more: Bool

    /// Newer sync endpoints can explicitly report that the requested cursor
    /// is outside their retention window. Older endpoints simply return a
    /// normal page, so all of these fields remain backward-compatible.
    let next_cursor: String?
    let full_sync_required: Bool
    let gap: Bool

    var requiresFullSync: Bool {
        full_sync_required || gap
    }

    var effectiveNextCursor: String {
        if let next_cursor, !next_cursor.isEmpty {
            return next_cursor
        }
        return cursor
    }

    private enum CodingKeys: String, CodingKey {
        case cursor, changes, has_more, next_cursor, full_sync_required, gap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor) ?? ""
        changes = try container.decodeIfPresent([PhoneChange].self, forKey: .changes) ?? []
        has_more = try container.decodeIfPresent(Bool.self, forKey: .has_more) ?? false
        next_cursor = try container.decodeIfPresent(String.self, forKey: .next_cursor)
        full_sync_required = try container.decodeIfPresent(Bool.self, forKey: .full_sync_required) ?? false
        gap = try container.decodeIfPresent(Bool.self, forKey: .gap) ?? false
    }
}

struct PendingSyncEvent: Codable, Identifiable, Hashable {
    let event_id: String
    let event_name: String
    let received_at: Date

    var id: String { event_id }
}

struct PendingOperation: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case reply
        case confirm
    }

    enum Status: String, Codable, CaseIterable {
        case pending
        case inFlight = "in_flight"
        case failed
    }

    /// The server idempotency key is the durable identity of a local intent.
    /// It must remain unchanged across retries and app relaunches.
    let idempotency_key: String
    let kind: Kind
    let session_id: String
    let action_key: String?
    let action_id: String?
    let confirm: Bool?
    let created_at: Date
    var status: Status
    var lastError: String?
    var failureCode: String?

    var id: String { idempotency_key }

    var isPending: Bool {
        status == .pending || status == .inFlight
    }

    init(
        idempotencyKey: String,
        kind: Kind,
        session_id: String,
        action_key: String?,
        action_id: String?,
        confirm: Bool?,
        created_at: Date,
        status: Status = .pending,
        lastError: String? = nil,
        failureCode: String? = nil
    ) {
        self.idempotency_key = idempotencyKey
        self.kind = kind
        self.session_id = session_id
        self.action_key = action_key
        self.action_id = action_id
        self.confirm = confirm
        self.created_at = created_at
        self.status = status
        self.lastError = lastError
        self.failureCode = failureCode
    }

    /// Compatibility initializer for the pre-G1 queue, where `id` was the
    /// implicit idempotency key.
    init(
        id: String,
        kind: Kind,
        session_id: String,
        action_key: String?,
        action_id: String?,
        confirm: Bool?,
        created_at: Date,
        status: Status = .pending,
        lastError: String? = nil,
        failureCode: String? = nil
    ) {
        self.init(
            idempotencyKey: id,
            kind: kind,
            session_id: session_id,
            action_key: action_key,
            action_id: action_id,
            confirm: confirm,
            created_at: created_at,
            status: status,
            lastError: lastError,
            failureCode: failureCode
        )
    }

    private enum CodingKeys: String, CodingKey {
        case idempotency_key, id, kind, session_id, action_key, action_id, confirm, created_at
        case status, lastError, last_error, failureCode, failure_code
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(idempotency_key, forKey: .idempotency_key)
        try container.encode(kind, forKey: .kind)
        try container.encode(session_id, forKey: .session_id)
        try container.encodeIfPresent(action_key, forKey: .action_key)
        try container.encodeIfPresent(action_id, forKey: .action_id)
        try container.encodeIfPresent(confirm, forKey: .confirm)
        try container.encode(created_at, forKey: .created_at)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encodeIfPresent(failureCode, forKey: .failureCode)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let canonicalKey = try container.decodeIfPresent(String.self, forKey: .idempotency_key)
        let legacyKey = try container.decodeIfPresent(String.self, forKey: .id)
        guard let resolvedKey = canonicalKey ?? legacyKey, !resolvedKey.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.idempotency_key,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Pending operation did not contain an idempotency key"
                )
            )
        }
        idempotency_key = resolvedKey
        kind = try container.decode(Kind.self, forKey: .kind)
        session_id = try container.decode(String.self, forKey: .session_id)
        action_key = try container.decodeIfPresent(String.self, forKey: .action_key)
        action_id = try container.decodeIfPresent(String.self, forKey: .action_id)
        confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)
        if let decodedDate = try? container.decode(Date.self, forKey: .created_at) {
            created_at = decodedDate
        } else if let decodedString = try? container.decode(String.self, forKey: .created_at),
                  let decodedDate = ISO8601DateFormatter().date(from: decodedString)
        {
            created_at = decodedDate
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .created_at,
                in: container,
                debugDescription: "Pending operation has an invalid created_at value"
            )
        }
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .pending
        let canonicalLastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        if let canonicalLastError {
            lastError = canonicalLastError
        } else {
            lastError = try container.decodeIfPresent(String.self, forKey: .last_error)
        }
        let canonicalFailureCode = try container.decodeIfPresent(String.self, forKey: .failureCode)
        if let canonicalFailureCode {
            failureCode = canonicalFailureCode
        } else {
            failureCode = try container.decodeIfPresent(String.self, forKey: .failure_code)
        }
    }
}

struct PendingCommandConfirmation: Codable, Equatable, Identifiable {
    let command_id: String
    let confirmation_token: String
    let title: String
    let risk: String
    let confirm_required: Bool
    let reversible: Bool

    var id: String { command_id }
}

struct PhoneReplyResponse: Decodable {
    let session: Session
    let action: PendingAction
    let needs_confirm: Bool?
}

struct CommandResponse: Decodable, Equatable {
    let command_id: String
    let state: String
    let command: CommandEnvelope?
    let action: CommandActionMetadata?
    let confirmation_token: String?
    let result: JSONValue?
    let error: CommandResponseError?
    let undo_command_id: String?
    let version: Int?
    let created_at: String?
    let updated_at: String?
}

struct CommandActionMetadata: Decodable, Equatable {
    let title: String
    let risk: String
    let confirm_required: Bool
    let reversible: Bool
}

struct CommandResponseError: Decodable, Equatable {
    let code: String
    let message: String
    let retryable: Bool
}

struct ModelArtifactDescriptorResponse: Decodable, Equatable {
    let model_id: String
    let manifest: ModelManifest
    let download_url: String
    let expires_at: String?
}

struct PendingAction: Decodable {
    let action_id: String
    let session_id: String
    let action_key: String
    let title: String?
    let risk: String
    let confirm_required: Bool?
    let status: String
    let expires_at: String

    enum CodingKeys: String, CodingKey {
        case action_id, session_id, action_key, title, risk, confirm_required, status, expires_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action_id = try c.decode(String.self, forKey: .action_id)
        session_id = try c.decode(String.self, forKey: .session_id)
        action_key = try c.decode(String.self, forKey: .action_key)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        risk = try c.decodeIfPresent(String.self, forKey: .risk) ?? "unknown"
        confirm_required = try c.decodeIfPresent(Bool.self, forKey: .confirm_required)
        status = try c.decode(String.self, forKey: .status)
        expires_at = try c.decodeIfPresent(String.self, forKey: .expires_at) ?? ""
    }
}

struct APIErrorBody: Decodable {
    let error: String?
    let message: String?
    let retryable: Bool?
    let request_id: String?
    let retry_after: Int?

    private struct Envelope: Decodable {
        let code: String?
        let message: String?
        let retryable: Bool?
        let request_id: String?
        let retry_after: Int?
    }

    private enum CodingKeys: String, CodingKey {
        case error, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var decodedMessage = try container.decodeIfPresent(String.self, forKey: .message)
        if let legacy = try? container.decode(String.self, forKey: .error) {
            error = legacy
            retryable = nil
            request_id = nil
            retry_after = nil
        } else if let envelope = try? container.decode(Envelope.self, forKey: .error) {
            error = envelope.code
            if decodedMessage == nil {
                decodedMessage = envelope.message
            }
            retryable = envelope.retryable
            request_id = envelope.request_id
            retry_after = envelope.retry_after
        } else {
            error = nil
            retryable = nil
            request_id = nil
            retry_after = nil
        }
        message = decodedMessage
    }
}

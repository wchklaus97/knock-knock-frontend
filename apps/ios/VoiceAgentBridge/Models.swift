import Foundation

struct AuthResponse: Decodable {
    let user_id: String
    let token: String
    let refresh_token: String?
    let expires_in: Int?
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
    let session_id: String?
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
    let voice_script: String?
    let available_actions: [String]?
    let facts: [String: JSONValue]
    let expires_at: String
    let created_at: String
    let updated_at: String

    var needsUser: Bool { state == "needs_user" || state == "awaiting_confirm" }

    enum CodingKeys: String, CodingKey {
        case session_id, agent_id, skill_id, state
        case progress_status, progress_message, progress_percent, chat_id, title
        case summary_text, voice_script, available_actions, facts
        case expires_at, created_at, updated_at
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
        facts = try c.decodeIfPresent([String: JSONValue].self, forKey: .facts) ?? [:]
        expires_at = try c.decodeIfPresent(String.self, forKey: .expires_at) ?? ""
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at) ?? ""
        updated_at = try c.decodeIfPresent(String.self, forKey: .updated_at) ?? ""
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
}

struct DevPush: Codable, Identifiable {
    var id: String { push_id }
    let push_id: String
    let session_id: String
    let title: String
    let body: String
    let voice_script: String?
    let created_at: String
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
}

struct PhoneChange: Decodable {
    let cursor: String
    let entity_type: String
    let entity_id: String
    let session_id: String?
    let version: Int
}

struct SyncResponse: Decodable {
    let cursor: String
    let changes: [PhoneChange]
    let has_more: Bool
}

struct PendingOperation: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case reply
        case confirm
    }

    let id: String
    let kind: Kind
    let session_id: String
    let action_key: String?
    let action_id: String?
    let confirm: Bool?
    let created_at: Date
}

struct PhoneReplyResponse: Decodable {
    let session: Session
    let action: PendingAction
    let needs_confirm: Bool?
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
        risk = try c.decodeIfPresent(String.self, forKey: .risk) ?? "low"
        confirm_required = try c.decodeIfPresent(Bool.self, forKey: .confirm_required)
        status = try c.decode(String.self, forKey: .status)
        expires_at = try c.decodeIfPresent(String.self, forKey: .expires_at) ?? ""
    }
}

struct APIErrorBody: Decodable {
    let error: String?
    let message: String?

    private struct Envelope: Decodable {
        let code: String?
        let message: String?
    }

    private enum CodingKeys: String, CodingKey {
        case error, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var decodedMessage = try container.decodeIfPresent(String.self, forKey: .message)
        if let legacy = try? container.decode(String.self, forKey: .error) {
            error = legacy
        } else if let envelope = try? container.decode(Envelope.self, forKey: .error) {
            error = envelope.code
            if decodedMessage == nil {
                decodedMessage = envelope.message
            }
        } else {
            error = nil
        }
        message = decodedMessage
    }
}

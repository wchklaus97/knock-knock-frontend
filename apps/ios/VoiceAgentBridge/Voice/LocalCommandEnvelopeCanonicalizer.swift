import Foundation

/// Context that comes from trusted app state rather than model output.
/// The local model can classify intent and extract arguments, but it cannot
/// choose identifiers, device context, or the signed model version recorded by
/// the backend.
struct LocalCommandEnvelopeContext: Equatable {
    let modelVersion: String
    let locale: String
    let timezone: String
    let deviceID: String?
    let sessionID: String?

    init(
        modelVersion: String,
        locale: Locale = .current,
        timezone: TimeZone = .current,
        deviceID: String? = nil,
        sessionID: String? = nil
    ) {
        self.modelVersion = modelVersion
        self.locale = locale.identifier.replacingOccurrences(of: "_", with: "-")
        self.timezone = timezone.identifier
        self.deviceID = deviceID
        self.sessionID = sessionID
    }

    init(
        modelVersion: String,
        localeIdentifier: String,
        timezoneIdentifier: String,
        deviceID: String? = nil,
        sessionID: String? = nil
    ) {
        self.modelVersion = modelVersion
        self.locale = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        self.timezone = timezoneIdentifier
        self.deviceID = deviceID
        self.sessionID = sessionID
    }
}

enum LocalCommandEnvelopeCanonicalizerError: Error, Equatable {
    enum ClarificationReason: Equatable {
        case lowConfidence
        case modelRequestedClarification
        case unsupportedIntent
        case invalidModelOutput
    }

    case clarificationRequired(ClarificationReason)
}

/// Shared classifier for errors crossing the untrusted local-model boundary.
/// Semantic uncertainty asks the user to clarify; runtime or transport errors
/// remain failures and must never be disguised as an ambiguous utterance.
enum LocalVoiceCommandErrorPolicy {
    static func requiresClarification(_ error: Error) -> Bool {
        if error is LocalCommandEnvelopeCanonicalizerError {
            return true
        }
        return (error as? LocalVoiceAdapterError) == .invalidModelOutput
    }
}

/// The model-facing DTO. It intentionally mirrors the currently deployed
/// prompt, but none of its transport or policy claims are authoritative.
private struct LocalModelCommandDraft: Decodable {
    let schemaVersion: Int
    let commandID: String
    let intent: String
    let args: [String: JSONValue]
    let claimedRiskLevel: CommandEnvelope.RiskLevel
    let claimedNeedsConfirmation: Bool
    let idempotencyKey: String
    let confidence: Double
    let locale: String
    let timezone: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case commandID = "command_id"
        case intent
        case args
        case claimedRiskLevel = "risk_level"
        case claimedNeedsConfirmation = "needs_confirmation"
        case idempotencyKey = "idempotency_key"
        case confidence
        case locale
        case timezone
    }

    init(from decoder: Decoder) throws {
        try StrictDecoding.rejectUnknownKeys(
            in: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        commandID = try container.decode(String.self, forKey: .commandID)
        intent = try container.decode(String.self, forKey: .intent)
        args = try container.decode([String: JSONValue].self, forKey: .args)
        claimedRiskLevel = try container.decode(
            CommandEnvelope.RiskLevel.self,
            forKey: .claimedRiskLevel
        )
        claimedNeedsConfirmation = try container.decode(
            Bool.self,
            forKey: .claimedNeedsConfirmation
        )
        idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
        confidence = try container.decode(Double.self, forKey: .confidence)
        locale = try container.decode(String.self, forKey: .locale)
        timezone = try container.decode(String.self, forKey: .timezone)
    }

    static func decodeStrict(from data: Data) throws -> LocalModelCommandDraft {
        guard !data.isEmpty, data.count <= CommandEnvelope.maximumEncodedSize else {
            throw CommandEnvelopeError.encodedSizeOutOfRange
        }
        try StrictJSON.validate(data)
        return try JSONDecoder().decode(LocalModelCommandDraft.self, from: data)
    }
}

struct LocalVoiceCommandSemantics: Equatable {
    let intent: String
    let args: [String: JSONValue]
    let riskLevel: CommandEnvelope.RiskLevel
    let needsConfirmation: Bool
}

/// Local semantic policy is an allowlist. Confidence can only reject an
/// otherwise valid command; it never makes an unsupported shape executable.
enum LocalVoiceCommandPolicy {
    static let minimumConfidence = 0.5

    private enum SupportedIntent: String {
        case searchHistory = "search_history"
        case createReminder = "create_reminder"
        case createDraft = "create_draft"
        case sendMessage = "send_message"
    }

    private static let clarificationIntents: Set<String> = [
        "ambiguous",
        "clarification",
        "clarify",
        "invalid",
        "unknown",
        "unsupported",
        "unsupported_intent",
    ]

    static func semantics(
        intent: String,
        args: [String: JSONValue],
        confidence: Double
    ) throws -> LocalVoiceCommandSemantics {
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw clarification(.invalidModelOutput)
        }

        guard let supportedIntent = SupportedIntent(rawValue: intent) else {
            let normalized = intent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if clarificationIntents.contains(normalized) {
                throw clarification(.modelRequestedClarification)
            }
            throw clarification(.unsupportedIntent)
        }

        let semantics: LocalVoiceCommandSemantics
        switch supportedIntent {
        case .searchHistory:
            try requireOnly(args, keys: ["q", "query", "text"])
            let query = try requiredString(
                in: args,
                aliases: ["q", "query", "text"],
                maximumCharacters: 200
            )
            semantics = LocalVoiceCommandSemantics(
                intent: supportedIntent.rawValue,
                args: ["q": .string(query)],
                riskLevel: .low,
                needsConfirmation: false
            )

        case .createReminder:
            try requireOnly(
                args,
                keys: ["title", "text", "message", "due_at", "time", "datetime"]
            )
            let title = try requiredString(
                in: args,
                aliases: ["title", "text", "message"],
                maximumCharacters: 200
            )
            let dueAt = try requiredString(
                in: args,
                aliases: ["due_at", "time", "datetime"],
                maximumCharacters: 64
            )
            semantics = LocalVoiceCommandSemantics(
                intent: supportedIntent.rawValue,
                args: ["title": .string(title), "due_at": .string(dueAt)],
                riskLevel: .low,
                needsConfirmation: false
            )

        case .createDraft:
            try requireOnly(args, keys: ["body", "content", "text", "title", "subject"])
            let body = try requiredString(
                in: args,
                aliases: ["body", "content", "text"],
                maximumCharacters: 4_096
            )
            let title = try optionalString(
                in: args,
                aliases: ["title", "subject"],
                maximumCharacters: 200
            )
            var canonicalArgs: [String: JSONValue] = ["body": .string(body)]
            if let title {
                canonicalArgs["title"] = .string(title)
            }
            semantics = LocalVoiceCommandSemantics(
                intent: supportedIntent.rawValue,
                args: canonicalArgs,
                riskLevel: .low,
                needsConfirmation: false
            )

        case .sendMessage:
            try requireOnly(
                args,
                keys: ["recipient", "to", "body", "content", "message"]
            )
            let recipient = try requiredString(
                in: args,
                aliases: ["recipient", "to"],
                maximumCharacters: 320
            )
            let body = try requiredString(
                in: args,
                aliases: ["body", "content", "message"],
                maximumCharacters: 4_096
            )
            semantics = LocalVoiceCommandSemantics(
                intent: supportedIntent.rawValue,
                args: ["recipient": .string(recipient), "body": .string(body)],
                riskLevel: .high,
                needsConfirmation: true
            )
        }

        guard confidence >= minimumConfidence else {
            throw clarification(.lowConfidence)
        }
        return semantics
    }

    /// Defense in depth for generators used outside the production adapter.
    /// Rebuilds policy fields instead of trusting their encoded values.
    static func authoritativeEnvelope(from envelope: CommandEnvelope) throws -> CommandEnvelope {
        let local = try semantics(
            intent: envelope.intent,
            args: envelope.args,
            confidence: envelope.confidence
        )
        return try CommandEnvelope(
            schemaVersion: envelope.schemaVersion,
            commandID: envelope.commandID,
            intent: local.intent,
            args: local.args,
            riskLevel: local.riskLevel,
            needsConfirmation: local.needsConfirmation,
            idempotencyKey: envelope.idempotencyKey,
            confidence: envelope.confidence,
            locale: envelope.locale,
            timezone: envelope.timezone,
            deviceID: envelope.deviceID,
            sessionID: envelope.sessionID,
            modelVersion: envelope.modelVersion
        )
    }

    private static func requireOnly(
        _ args: [String: JSONValue],
        keys allowedKeys: Set<String>
    ) throws {
        guard Set(args.keys).isSubset(of: allowedKeys) else {
            throw clarification(.invalidModelOutput)
        }
    }

    private static func requiredString(
        in args: [String: JSONValue],
        aliases: [String],
        minimumUTF8Length: Int = 1,
        maximumCharacters: Int
    ) throws -> String {
        guard let value = try optionalString(
            in: args,
            aliases: aliases,
            minimumUTF8Length: minimumUTF8Length,
            maximumCharacters: maximumCharacters
        ) else {
            throw clarification(.invalidModelOutput)
        }
        return value
    }

    private static func optionalString(
        in args: [String: JSONValue],
        aliases: [String],
        minimumUTF8Length: Int = 1,
        maximumCharacters: Int
    ) throws -> String? {
        let presentKeys = aliases.filter { args[$0] != nil }
        guard presentKeys.count <= 1 else {
            throw clarification(.invalidModelOutput)
        }
        guard let key = presentKeys.first else {
            return nil
        }
        guard case let .string(value)? = args[key] else {
            throw clarification(.invalidModelOutput)
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.count >= minimumUTF8Length,
              normalized.count <= maximumCharacters,
              normalized.utf8.count <= 4_096
        else {
            throw clarification(.invalidModelOutput)
        }
        return normalized
    }

    private static func clarification(
        _ reason: LocalCommandEnvelopeCanonicalizerError.ClarificationReason
    ) -> LocalCommandEnvelopeCanonicalizerError {
        .clarificationRequired(reason)
    }
}

/// Converts an untrusted model DTO into the canonical wire envelope. IDs,
/// context, risk, confirmation, intent allowlisting, and argument names are all
/// owned by local code; the backend still performs final revalidation.
struct LocalCommandEnvelopeCanonicalizer {
    private let makeIdentifier: () -> String

    init(makeIdentifier: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.makeIdentifier = makeIdentifier
    }

    func canonicalize(
        modelOutput: Data,
        context: LocalCommandEnvelopeContext
    ) throws -> Data {
        let draft: LocalModelCommandDraft
        let local: LocalVoiceCommandSemantics
        do {
            draft = try LocalModelCommandDraft.decodeStrict(from: modelOutput)
            guard draft.schemaVersion == CommandEnvelope.supportedVersion else {
                throw CommandEnvelopeError.unsupportedVersion
            }
            local = try LocalVoiceCommandPolicy.semantics(
                intent: draft.intent,
                args: draft.args,
                confidence: draft.confidence
            )
        } catch let error as LocalCommandEnvelopeCanonicalizerError {
            throw error
        } catch {
            throw LocalCommandEnvelopeCanonicalizerError.clarificationRequired(
                .invalidModelOutput
            )
        }

        let envelope = try CommandEnvelope(
            commandID: "cmd_voice_\(makeIdentifier())",
            intent: local.intent,
            args: local.args,
            riskLevel: local.riskLevel,
            needsConfirmation: local.needsConfirmation,
            idempotencyKey: "idem_voice_\(makeIdentifier())",
            confidence: draft.confidence,
            locale: context.locale,
            timezone: context.timezone,
            deviceID: context.deviceID,
            sessionID: context.sessionID,
            modelVersion: context.modelVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }
}

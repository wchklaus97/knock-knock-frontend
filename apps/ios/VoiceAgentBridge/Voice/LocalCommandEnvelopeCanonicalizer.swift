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
        /// Send-message body was grounded, but the recipient was a pronoun or
        /// otherwise unnamed. Callers must not invent a person to fill this.
        /// `body` may be empty when the user has not said the message yet.
        case missingSendRecipient(body: String)
        /// Recipient is named, but the message body was never said.
        case missingSendBody(recipient: String)
    }

    case clarificationRequired(ClarificationReason)
}

enum LocalCommandClock {
    static func currentMilliseconds() -> Int64 {
        let milliseconds = Date().timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite else { return 0 }
        if milliseconds <= Double(Int64.min) { return Int64.min }
        if milliseconds >= Double(Int64.max) { return Int64.max }
        return Int64(milliseconds.rounded(.down))
    }
}

/// Mirrors the backend's reminder timestamp parser. Keeping this boundary
/// strict prevents a model-produced relative time from appearing valid on the
/// phone only to be rejected (or interpreted differently) by the backend.
enum LocalReminderDueAt {
    static func parseMilliseconds(_ timestamp: String) -> Int64? {
        let bytes = Array(timestamp.utf8)
        guard bytes.count >= 20,
              bytes[4] == 0x2D,
              bytes[7] == 0x2D,
              bytes[10] == 0x54 || bytes[10] == 0x74,
              bytes[13] == 0x3A,
              bytes[16] == 0x3A,
              let year = decimal(bytes, 0..<4),
              let month = decimal(bytes, 5..<7),
              let day = decimal(bytes, 8..<10),
              let hour = decimal(bytes, 11..<13),
              let minute = decimal(bytes, 14..<16),
              let second = decimal(bytes, 17..<19),
              day > 0,
              let maximumDay = daysInMonth(year: year, month: month),
              day <= maximumDay,
              hour <= 23,
              minute <= 59,
              second <= 59
        else {
            return nil
        }

        var cursor = 19
        var milliseconds = 0
        var fractionalDigits = 0
        if bytes.indices.contains(cursor), bytes[cursor] == 0x2E {
            cursor += 1
            let fractionStart = cursor
            while bytes.indices.contains(cursor), bytes[cursor].isASCIIDigit {
                guard fractionalDigits < 3 else { return nil }
                milliseconds = milliseconds * 10 + Int(bytes[cursor] - 48)
                fractionalDigits += 1
                cursor += 1
            }
            guard cursor > fractionStart else { return nil }
            while fractionalDigits < 3 {
                milliseconds *= 10
                fractionalDigits += 1
            }
        }

        guard bytes.indices.contains(cursor) else { return nil }
        let offsetSeconds: Int64
        switch bytes[cursor] {
        case 0x5A, 0x7A:
            guard cursor + 1 == bytes.count else { return nil }
            offsetSeconds = 0
        case 0x2B, 0x2D:
            guard cursor + 6 == bytes.count,
                  bytes[cursor + 3] == 0x3A,
                  let offsetHour = decimal(bytes, (cursor + 1)..<(cursor + 3)),
                  let offsetMinute = decimal(bytes, (cursor + 4)..<(cursor + 6)),
                  offsetHour <= 23,
                  offsetMinute <= 59
            else {
                return nil
            }
            let magnitude = Int64(offsetHour * 3_600 + offsetMinute * 60)
            offsetSeconds = bytes[cursor] == 0x2B ? magnitude : -magnitude
        default:
            return nil
        }

        let unixSeconds = daysFromCivil(year: year, month: month, day: day) * 86_400
            + Int64(hour * 3_600 + minute * 60 + second)
            - offsetSeconds
        let (scaledSeconds, multiplyOverflow) = unixSeconds.multipliedReportingOverflow(by: 1_000)
        let (result, additionOverflow) = scaledSeconds.addingReportingOverflow(Int64(milliseconds))
        return multiplyOverflow || additionOverflow ? nil : result
    }

    static func isStrictlyFuture(
        _ timestamp: String,
        relativeToMilliseconds referenceMilliseconds: Int64
    ) -> Bool {
        guard let dueAtMilliseconds = parseMilliseconds(timestamp) else { return false }
        return dueAtMilliseconds > referenceMilliseconds
    }

    private static func decimal(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return nil }
        var value = 0
        for index in range {
            guard bytes[index].isASCIIDigit else { return nil }
            value = value * 10 + Int(bytes[index] - 48)
        }
        return value
    }

    private static func daysInMonth(year: Int, month: Int) -> Int? {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12:
            return 31
        case 4, 6, 9, 11:
            return 30
        case 2:
            return isLeapYear(year) ? 29 : 28
        default:
            return nil
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }

    // Howard Hinnant's civil-date conversion, shifted to the Unix epoch.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        let adjustedYear = Int64(year) - (month <= 2 ? 1 : 0)
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = Int64(month)
        let dayOfYear = (153 * (adjustedMonth + (month > 2 ? -3 : 9)) + 2) / 5
            + Int64(day) - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { (48...57).contains(self) }
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

/// The model-facing DTO contains semantics only. Transport identity, locale,
/// timezone, risk, and confirmation policy are deliberately absent so a model
/// can neither choose nor weaken them.
private struct LocalModelCommandDraft: Decodable {
    let intent: String
    let args: [String: JSONValue]
    let confidence: Double

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case intent
        case args
        case confidence
    }

    init(from decoder: Decoder) throws {
        try StrictDecoding.rejectUnknownKeys(
            in: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intent = try container.decode(String.self, forKey: .intent)
        args = try container.decode([String: JSONValue].self, forKey: .args)
        confidence = try container.decode(Double.self, forKey: .confidence)
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
        confidence: Double,
        referenceMilliseconds: Int64 = LocalCommandClock.currentMilliseconds()
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
            guard LocalReminderDueAt.isStrictlyFuture(
                dueAt,
                relativeToMilliseconds: referenceMilliseconds
            ) else {
                throw clarification(.invalidModelOutput)
            }
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
    static func authoritativeEnvelope(
        from envelope: CommandEnvelope,
        referenceMilliseconds: Int64 = LocalCommandClock.currentMilliseconds()
    ) throws -> CommandEnvelope {
        let local = try semantics(
            intent: envelope.intent,
            args: envelope.args,
            confidence: envelope.confidence,
            referenceMilliseconds: referenceMilliseconds
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
        context: LocalCommandEnvelopeContext,
        validationMilliseconds: Int64 = LocalCommandClock.currentMilliseconds()
    ) throws -> Data {
        let draft: LocalModelCommandDraft
        let local: LocalVoiceCommandSemantics
        do {
            draft = try LocalModelCommandDraft.decodeStrict(from: modelOutput)
            local = try LocalVoiceCommandPolicy.semantics(
                intent: draft.intent,
                args: draft.args,
                confidence: draft.confidence,
                referenceMilliseconds: validationMilliseconds
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

import Foundation

/// The only shape allowed to cross from a local intent model into the app and
/// backend. It intentionally matches the canonical backend CommandEnvelope v1
/// contract; local models never receive an API client or an executable action.
struct CommandEnvelope: Codable, Equatable {
    static let supportedVersion = 1
    static let maximumEncodedSize = 64 * 1024

    enum RiskLevel: String, Codable {
        case low
        case medium
        case high
        case destructive
    }

    let schemaVersion: Int
    let commandID: String
    let intent: String
    let args: [String: JSONValue]
    let riskLevel: RiskLevel
    let needsConfirmation: Bool
    let idempotencyKey: String
    let confidence: Double
    let locale: String
    let timezone: String
    let deviceID: String?
    let sessionID: String?
    let modelVersion: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case commandID = "command_id"
        case intent
        case args
        case riskLevel = "risk_level"
        case needsConfirmation = "needs_confirmation"
        case idempotencyKey = "idempotency_key"
        case confidence
        case locale
        case timezone
        case deviceID = "device_id"
        case sessionID = "session_id"
        case modelVersion = "model_version"
    }

    init(
        schemaVersion: Int = supportedVersion,
        commandID: String,
        intent: String,
        args: [String: JSONValue],
        riskLevel: RiskLevel,
        needsConfirmation: Bool,
        idempotencyKey: String,
        confidence: Double,
        locale: String,
        timezone: String,
        deviceID: String? = nil,
        sessionID: String? = nil,
        modelVersion: String? = nil
    ) throws {
        self.schemaVersion = schemaVersion
        self.commandID = commandID
        self.intent = intent
        self.args = args
        self.riskLevel = riskLevel
        self.needsConfirmation = needsConfirmation
        self.idempotencyKey = idempotencyKey
        self.confidence = confidence
        self.locale = locale
        self.timezone = timezone
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.modelVersion = modelVersion
        try validate()
    }

    init(from decoder: Decoder) throws {
        try StrictDecoding.rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        commandID = try container.decode(String.self, forKey: .commandID)
        intent = try container.decode(String.self, forKey: .intent)
        args = try container.decode([String: JSONValue].self, forKey: .args)
        riskLevel = try container.decode(RiskLevel.self, forKey: .riskLevel)
        needsConfirmation = try container.decode(Bool.self, forKey: .needsConfirmation)
        idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
        confidence = try container.decode(Double.self, forKey: .confidence)
        locale = try container.decode(String.self, forKey: .locale)
        timezone = try container.decode(String.self, forKey: .timezone)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        modelVersion = try container.decodeIfPresent(String.self, forKey: .modelVersion)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(commandID, forKey: .commandID)
        try container.encode(intent, forKey: .intent)
        try container.encode(args, forKey: .args)
        try container.encode(riskLevel, forKey: .riskLevel)
        try container.encode(needsConfirmation, forKey: .needsConfirmation)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(locale, forKey: .locale)
        try container.encode(timezone, forKey: .timezone)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(modelVersion, forKey: .modelVersion)
    }

    static func decodeStrict(from data: Data) throws -> CommandEnvelope {
        guard !data.isEmpty, data.count <= maximumEncodedSize else {
            throw CommandEnvelopeError.encodedSizeOutOfRange
        }
        return try JSONDecoder().decode(CommandEnvelope.self, from: data)
    }

    private func validate() throws {
        guard schemaVersion == Self.supportedVersion else {
            throw CommandEnvelopeError.unsupportedVersion
        }
        guard !commandID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              commandID.utf8.count <= 128,
              commandID.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
        else {
            throw CommandEnvelopeError.invalidCommandID
        }
        guard !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              intent.utf8.count <= 128,
              intent.range(of: #"^[a-z][a-z0-9_.-]*$"#, options: .regularExpression) != nil
        else {
            throw CommandEnvelopeError.invalidIntent
        }
        guard args.count <= 64 else { throw CommandEnvelopeError.argumentsTooLarge }
        for (key, value) in args {
            guard key.utf8.count <= 64,
                  key.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
            else { throw CommandEnvelopeError.invalidArgumentName }
            try value.validate(depth: 0)
        }
        guard !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              idempotencyKey.utf8.count <= 200
        else { throw CommandEnvelopeError.invalidIdempotencyKey }
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw CommandEnvelopeError.invalidConfidence
        }
        guard !locale.isEmpty, locale.utf8.count <= 32 else {
            throw CommandEnvelopeError.invalidLocale
        }
        guard !timezone.isEmpty, timezone.utf8.count <= 64 else {
            throw CommandEnvelopeError.invalidTimezone
        }
        for optional in [deviceID, sessionID, modelVersion].compactMap({ $0 }) {
            guard optional.utf8.count <= 128 else { throw CommandEnvelopeError.optionalFieldTooLong }
        }
    }
}

enum CommandEnvelopeError: Error, Equatable {
    case encodedSizeOutOfRange
    case unsupportedVersion
    case invalidCommandID
    case invalidIntent
    case invalidArgumentName
    case argumentsTooLarge
    case invalidIdempotencyKey
    case invalidConfidence
    case invalidLocale
    case invalidTimezone
    case optionalFieldTooLong
    case valueTooDeep
    case valueTooLarge
    case nonFiniteNumber
}

private extension JSONValue {
    func validate(depth: Int) throws {
        guard depth <= 8 else { throw CommandEnvelopeError.valueTooDeep }
        switch self {
        case .null, .bool:
            return
        case .number(let value):
            guard value.isFinite else { throw CommandEnvelopeError.nonFiniteNumber }
        case .string(let value):
            guard value.utf8.count <= 4_096 else { throw CommandEnvelopeError.valueTooLarge }
        case .array(let values):
            guard values.count <= 64 else { throw CommandEnvelopeError.valueTooLarge }
            try values.forEach { try $0.validate(depth: depth + 1) }
        case .object(let values):
            guard values.count <= 64 else { throw CommandEnvelopeError.valueTooLarge }
            for (key, value) in values {
                guard key.utf8.count <= 64 else { throw CommandEnvelopeError.valueTooLarge }
                try value.validate(depth: depth + 1)
            }
        }
    }
}

struct StrictCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum StrictDecoding {
    static func rejectUnknownKeys(in decoder: Decoder, allowed: [String]) throws {
        let container = try decoder.container(keyedBy: StrictCodingKey.self)
        let allowedKeys = Set(allowed)
        if let unknown = container.allKeys.first(where: { !allowedKeys.contains($0.stringValue) }) {
            throw DecodingError.dataCorruptedError(
                forKey: unknown,
                in: container,
                debugDescription: "Unknown key '\(unknown.stringValue)'"
            )
        }
    }
}

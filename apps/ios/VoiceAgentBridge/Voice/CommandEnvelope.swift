import Foundation

/// The authoritative wire envelope sent to, and revalidated by, the backend.
/// Local model output is decoded into a separate DTO before this value can be
/// constructed.
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
        try StrictJSON.validate(data)
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
            guard !optional.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  optional.utf8.count <= 128
            else { throw CommandEnvelopeError.invalidOptionalField }
        }
    }
}

enum CommandEnvelopeError: Error, Equatable {
    case encodedSizeOutOfRange
    case malformedJSON
    case duplicateJSONKey(String)
    case unsupportedVersion
    case invalidCommandID
    case invalidIntent
    case invalidArgumentName
    case argumentsTooLarge
    case invalidIdempotencyKey
    case invalidConfidence
    case invalidLocale
    case invalidTimezone
    case invalidOptionalField
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

/// `JSONDecoder` accepts duplicate object keys and keeps one value. That is not
/// safe for command policy fields, so every object is checked before decoding.
enum StrictJSON {
    static func validate(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.parseDocument()
    }

    private struct Parser {
        private static let maximumNestingDepth = 64

        let bytes: [UInt8]
        var index = 0

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else {
                throw CommandEnvelopeError.malformedJSON
            }
        }

        private mutating func parseValue(depth: Int) throws {
            guard depth <= Self.maximumNestingDepth, index < bytes.count else {
                throw CommandEnvelopeError.malformedJSON
            }

            switch bytes[index] {
            case 0x7B: // {
                try parseObject(depth: depth)
            case 0x5B: // [
                try parseArray(depth: depth)
            case 0x22: // "
                _ = try parseString()
            case 0x74: // true
                try consumeLiteral([0x74, 0x72, 0x75, 0x65])
            case 0x66: // false
                try consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
            case 0x6E: // null
                try consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
            case 0x2D, 0x30...0x39: // - or digit
                try parseNumber()
            default:
                throw CommandEnvelopeError.malformedJSON
            }
        }

        private mutating func parseObject(depth: Int) throws {
            index += 1
            skipWhitespace()
            if consume(0x7D) { // }
                return
            }

            var keys = Set<String>()
            while true {
                guard index < bytes.count, bytes[index] == 0x22 else {
                    throw CommandEnvelopeError.malformedJSON
                }
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw CommandEnvelopeError.duplicateJSONKey(key)
                }

                skipWhitespace()
                guard consume(0x3A) else { // :
                    throw CommandEnvelopeError.malformedJSON
                }
                skipWhitespace()
                try parseValue(depth: depth + 1)
                skipWhitespace()

                if consume(0x7D) { // }
                    return
                }
                guard consume(0x2C) else { // ,
                    throw CommandEnvelopeError.malformedJSON
                }
                skipWhitespace()
            }
        }

        private mutating func parseArray(depth: Int) throws {
            index += 1
            skipWhitespace()
            if consume(0x5D) { // ]
                return
            }

            while true {
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consume(0x5D) { // ]
                    return
                }
                guard consume(0x2C) else { // ,
                    throw CommandEnvelopeError.malformedJSON
                }
                skipWhitespace()
            }
        }

        private mutating func parseString() throws -> String {
            let start = index
            guard consume(0x22) else { // "
                throw CommandEnvelopeError.malformedJSON
            }

            while index < bytes.count {
                switch bytes[index] {
                case 0x22: // "
                    index += 1
                    do {
                        return try JSONDecoder().decode(
                            String.self,
                            from: Data(bytes[start..<index])
                        )
                    } catch {
                        throw CommandEnvelopeError.malformedJSON
                    }
                case 0x5C: // \
                    index += 1
                    guard index < bytes.count else {
                        throw CommandEnvelopeError.malformedJSON
                    }
                    index += 1
                case 0x00...0x1F:
                    throw CommandEnvelopeError.malformedJSON
                default:
                    index += 1
                }
            }
            throw CommandEnvelopeError.malformedJSON
        }

        private mutating func parseNumber() throws {
            _ = consume(0x2D) // -
            guard index < bytes.count else {
                throw CommandEnvelopeError.malformedJSON
            }

            if consume(0x30) { // 0
                if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    throw CommandEnvelopeError.malformedJSON
                }
            } else {
                guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else {
                    throw CommandEnvelopeError.malformedJSON
                }
                consumeDigits()
            }

            if consume(0x2E) { // .
                let fractionStart = index
                consumeDigits()
                guard index > fractionStart else {
                    throw CommandEnvelopeError.malformedJSON
                }
            }

            if consume(0x65) || consume(0x45) { // e or E
                _ = consume(0x2B) || consume(0x2D) // + or -
                let exponentStart = index
                consumeDigits()
                guard index > exponentStart else {
                    throw CommandEnvelopeError.malformedJSON
                }
            }
        }

        private mutating func consumeDigits() {
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                index += 1
            }
        }

        private mutating func consumeLiteral(_ literal: [UInt8]) throws {
            guard bytes[index...].starts(with: literal) else {
                throw CommandEnvelopeError.malformedJSON
            }
            index += literal.count
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else {
                return false
            }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while index < bytes.count,
                  bytes[index] == 0x20 || bytes[index] == 0x09
                    || bytes[index] == 0x0A || bytes[index] == 0x0D
            {
                index += 1
            }
        }
    }
}

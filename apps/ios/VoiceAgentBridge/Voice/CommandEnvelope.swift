import Foundation

/// The only JSON shape allowed to cross from a local language-model adapter into
/// application code. Keeping this boundary small prevents model output from being
/// treated as an executable command until it has passed deterministic validation.
struct CommandEnvelope: Codable, Equatable {
    static let supportedVersion = 1
    static let maximumEncodedSize = 64 * 1024

    let version: Int
    let id: UUID
    let issuedAt: Date
    let command: Command

    struct Command: Codable, Equatable {
        let name: String
        let arguments: [String: JSONValue]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case name
            case arguments
        }

        init(name: String, arguments: [String: JSONValue]) throws {
            self.name = name
            self.arguments = arguments
            try validate()
        }

        init(from decoder: Decoder) throws {
            try StrictDecoding.rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.rawValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            arguments = try container.decode([String: JSONValue].self, forKey: .arguments)
            try validate()
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        }

        private func validate() throws {
            guard name.range(of: #"^[a-z][a-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil else {
                throw CommandEnvelopeError.invalidCommandName
            }
            guard arguments.count <= 32 else {
                throw CommandEnvelopeError.argumentsTooLarge
            }
            for (key, value) in arguments {
                guard key.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil else {
                    throw CommandEnvelopeError.invalidArgumentName
                }
                try value.validate(depth: 0)
            }
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case id
        case issuedAt = "issued_at"
        case command
    }

    init(version: Int = supportedVersion, id: UUID, issuedAt: Date, command: Command) throws {
        self.version = version
        self.id = id
        self.issuedAt = issuedAt
        self.command = command
        try validate()
    }

    init(from decoder: Decoder) throws {
        try StrictDecoding.rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)

        let idValue = try container.decode(String.self, forKey: .id)
        guard let parsedID = UUID(uuidString: idValue) else {
            throw CommandEnvelopeError.invalidIdentifier
        }
        id = parsedID

        let issuedAtValue = try container.decode(String.self, forKey: .issuedAt)
        guard let parsedDate = Self.parseISO8601(issuedAtValue) else {
            throw CommandEnvelopeError.invalidIssuedAt
        }
        issuedAt = parsedDate
        command = try container.decode(Command.self, forKey: .command)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(Self.formatISO8601(issuedAt), forKey: .issuedAt)
        try container.encode(command, forKey: .command)
    }

    static func decodeStrict(from data: Data) throws -> CommandEnvelope {
        guard !data.isEmpty, data.count <= maximumEncodedSize else {
            throw CommandEnvelopeError.encodedSizeOutOfRange
        }
        return try JSONDecoder().decode(CommandEnvelope.self, from: data)
    }

    private func validate() throws {
        guard version == Self.supportedVersion else {
            throw CommandEnvelopeError.unsupportedVersion
        }
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private static func formatISO8601(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
}

enum CommandEnvelopeError: Error, Equatable {
    case encodedSizeOutOfRange
    case unsupportedVersion
    case invalidIdentifier
    case invalidIssuedAt
    case invalidCommandName
    case invalidArgumentName
    case argumentsTooLarge
    case valueTooDeep
    case valueTooLarge
    case nonFiniteNumber
}

private extension JSONValue {
    func validate(depth: Int) throws {
        guard depth <= 8 else {
            throw CommandEnvelopeError.valueTooDeep
        }
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

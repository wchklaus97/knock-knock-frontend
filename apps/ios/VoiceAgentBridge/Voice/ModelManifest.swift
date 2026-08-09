import CryptoKit
import Foundation

struct ModelManifest: Codable, Equatable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let modelID: String
    let modelVersion: String
    let sha256: String
    let signature: Data
    let sizeBytes: UInt64
    let minimumCapability: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case modelID = "model_id"
        case modelVersion = "model_version"
        case sha256
        case signature
        case sizeBytes = "size_bytes"
        case minimumCapability = "minimum_capability"
    }

    init(
        schemaVersion: Int = supportedSchemaVersion,
        modelID: String,
        modelVersion: String,
        sha256: String,
        signature: Data,
        sizeBytes: UInt64,
        minimumCapability: String
    ) throws {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.sha256 = sha256.lowercased()
        self.signature = signature
        self.sizeBytes = sizeBytes
        self.minimumCapability = minimumCapability
        try validate()
    }

    init(from decoder: Decoder) throws {
        try StrictDecoding.rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        modelID = try container.decode(String.self, forKey: .modelID)
        modelVersion = try container.decode(String.self, forKey: .modelVersion)
        sha256 = try container.decode(String.self, forKey: .sha256).lowercased()
        let encodedSignature = try container.decode(String.self, forKey: .signature)
        guard let decodedSignature = Data(base64Encoded: encodedSignature) else {
            throw ModelManifestError.invalidSignatureEncoding
        }
        signature = decodedSignature
        sizeBytes = try container.decode(UInt64.self, forKey: .sizeBytes)
        minimumCapability = try container.decode(String.self, forKey: .minimumCapability)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(modelVersion, forKey: .modelVersion)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(signature.base64EncodedString(), forKey: .signature)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(minimumCapability, forKey: .minimumCapability)
    }

    static func decodeStrict(from data: Data) throws -> ModelManifest {
        guard !data.isEmpty, data.count <= 64 * 1024 else {
            throw ModelManifestError.encodedSizeOutOfRange
        }
        return try JSONDecoder().decode(ModelManifest.self, from: data)
    }

    private func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw ModelManifestError.unsupportedSchemaVersion
        }
        guard modelID.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
            throw ModelManifestError.invalidModelID
        }
        guard SemanticVersion(modelVersion) != nil else {
            throw ModelManifestError.invalidModelVersion
        }
        guard sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw ModelManifestError.invalidHash
        }
        guard !signature.isEmpty else {
            throw ModelManifestError.invalidSignatureEncoding
        }
        guard sizeBytes > 0 else {
            throw ModelManifestError.invalidSize
        }
        guard minimumCapability.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else {
            throw ModelManifestError.invalidMinimumCapability
        }
    }
}

enum ModelManifestError: Error, Equatable {
    case encodedSizeOutOfRange
    case unsupportedSchemaVersion
    case invalidModelID
    case invalidModelVersion
    case invalidHash
    case invalidSignatureEncoding
    case invalidSize
    case invalidMinimumCapability
}

protocol ModelArtifactVerifying {
    /// Verifies bytes in-place. Implementations must not move or activate the artifact.
    func verifyArtifact(at url: URL, against manifest: ModelManifest) throws
}

enum ModelArtifactVerificationError: Error, Equatable {
    case unreadableArtifact
    case sizeMismatch(expected: UInt64, actual: UInt64)
    case hashMismatch
    case signatureMismatch
}

/// Production verifier for model artifacts. The Ed25519 signature covers the raw
/// 32-byte SHA-256 digest, while size and digest are independently checked first.
struct Ed25519ModelArtifactVerifier: ModelArtifactVerifying {
    let publicKey: Curve25519.Signing.PublicKey

    init(publicKeyRawRepresentation: Data) throws {
        publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRawRepresentation)
    }

    func verifyArtifact(at url: URL, against manifest: ModelManifest) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw ModelArtifactVerificationError.unreadableArtifact
        }
        guard let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
            throw ModelArtifactVerificationError.unreadableArtifact
        }
        guard fileSize == manifest.sizeBytes else {
            throw ModelArtifactVerificationError.sizeMismatch(expected: manifest.sizeBytes, actual: fileSize)
        }

        let digest = try Self.sha256(of: url)
        guard Self.hex(digest) == manifest.sha256 else {
            throw ModelArtifactVerificationError.hashMismatch
        }
        guard publicKey.isValidSignature(manifest.signature, for: digest) else {
            throw ModelArtifactVerificationError.signatureMismatch
        }
    }

    static func sha256(of url: URL) throws -> Data {
        guard let stream = InputStream(url: url) else {
            throw ModelArtifactVerificationError.unreadableArtifact
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw ModelArtifactVerificationError.unreadableArtifact
            }
            if count == 0 {
                break
            }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return Data(hasher.finalize())
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

protocol ModelCapabilityChecking {
    func supports(minimumCapability: String) -> Bool
}

struct DeclaredModelCapabilities: ModelCapabilityChecking {
    let identifiers: Set<String>

    func supports(minimumCapability: String) -> Bool {
        identifiers.contains(minimumCapability)
    }
}

struct InstalledModel: Equatable {
    let manifest: ModelManifest
    let artifactURL: URL
}

enum ModelSelectionError: Error, Equatable {
    case unsupportedCapability(String)
    case noRollbackCandidate
    case downgradeRejected
}

/// Verification completes before selection state changes. A failed update therefore
/// leaves the active model untouched, and the previous verified model remains an
/// explicit rollback candidate after a successful activation.
final class RollbackSafeModelSelector {
    private let verifier: ModelArtifactVerifying
    private let capabilities: ModelCapabilityChecking

    private(set) var activeModel: InstalledModel?
    private(set) var rollbackModel: InstalledModel?

    init(
        activeModel: InstalledModel? = nil,
        rollbackModel: InstalledModel? = nil,
        verifier: ModelArtifactVerifying,
        capabilities: ModelCapabilityChecking
    ) {
        self.activeModel = activeModel
        self.rollbackModel = rollbackModel
        self.verifier = verifier
        self.capabilities = capabilities
    }

    func activate(_ candidate: InstalledModel, allowDowngrade: Bool = false) throws {
        guard capabilities.supports(minimumCapability: candidate.manifest.minimumCapability) else {
            throw ModelSelectionError.unsupportedCapability(candidate.manifest.minimumCapability)
        }
        if
            !allowDowngrade,
            let activeVersion = activeModel.flatMap({ SemanticVersion($0.manifest.modelVersion) }),
            let candidateVersion = SemanticVersion(candidate.manifest.modelVersion),
            candidateVersion < activeVersion
        {
            throw ModelSelectionError.downgradeRejected
        }

        try verifier.verifyArtifact(at: candidate.artifactURL, against: candidate.manifest)

        if candidate != activeModel {
            rollbackModel = activeModel
            activeModel = candidate
        }
    }

    @discardableResult
    func activateBestVerified(from candidates: [InstalledModel]) -> InstalledModel? {
        let ordered = candidates.sorted {
            guard
                let lhs = SemanticVersion($0.manifest.modelVersion),
                let rhs = SemanticVersion($1.manifest.modelVersion)
            else { return $0.manifest.modelVersion > $1.manifest.modelVersion }
            return lhs > rhs
        }
        for candidate in ordered {
            do {
                try activate(candidate)
                return activeModel
            } catch {
                continue
            }
        }
        return activeModel
    }

    @discardableResult
    func rollback() throws -> InstalledModel {
        guard let candidate = rollbackModel else {
            throw ModelSelectionError.noRollbackCandidate
        }
        guard capabilities.supports(minimumCapability: candidate.manifest.minimumCapability) else {
            throw ModelSelectionError.unsupportedCapability(candidate.manifest.minimumCapability)
        }
        try verifier.verifyArtifact(at: candidate.artifactURL, against: candidate.manifest)

        let previousActive = activeModel
        activeModel = candidate
        rollbackModel = previousActive
        return candidate
    }
}

private struct SemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let suffix: String

    init?(_ value: String) {
        let pattern = #"^([0-9]+)\.([0-9]+)\.([0-9]+)([-+][0-9A-Za-z.-]+)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard
            let match = expression.firstMatch(in: value, range: range),
            match.range == range,
            let majorRange = Range(match.range(at: 1), in: value),
            let minorRange = Range(match.range(at: 2), in: value),
            let patchRange = Range(match.range(at: 3), in: value),
            let major = Int(value[majorRange]),
            let minor = Int(value[minorRange]),
            let patch = Int(value[patchRange])
        else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
        if let suffixRange = Range(match.range(at: 4), in: value) {
            suffix = String(value[suffixRange])
        } else {
            suffix = ""
        }
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.suffix.isEmpty != rhs.suffix.isEmpty { return !lhs.suffix.isEmpty }
        return lhs.suffix < rhs.suffix
    }
}

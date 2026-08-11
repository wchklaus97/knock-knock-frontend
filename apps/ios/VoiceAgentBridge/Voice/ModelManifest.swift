import CryptoKit
import Foundation

struct ModelManifest: Codable, Equatable {
    static let supportedSchemaVersion = 1
    static let maximumArtifactSizeBytes: UInt64 = 2 * 1024 * 1024 * 1024
    static let signatureDomain = "com.knockknock.voice-model-manifest.ed25519.v1"

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

    /// The signature binds the artifact digest to all security-relevant manifest
    /// metadata. Values are validated as separator-free ASCII before this payload
    /// is used, and the final newline is part of the versioned wire format.
    var signaturePayload: Data {
        Self.signaturePayload(
            schemaVersion: schemaVersion,
            modelID: modelID,
            modelVersion: modelVersion,
            sha256: sha256,
            sizeBytes: sizeBytes,
            minimumCapability: minimumCapability
        )
    }

    static func signaturePayload(
        schemaVersion: Int,
        modelID: String,
        modelVersion: String,
        sha256: String,
        sizeBytes: UInt64,
        minimumCapability: String
    ) -> Data {
        let lines = [
            signatureDomain,
            "schema_version=\(schemaVersion)",
            "model_id=\(modelID)",
            "model_version=\(modelVersion)",
            "sha256=\(sha256.lowercased())",
            "size_bytes=\(sizeBytes)",
            "minimum_capability=\(minimumCapability)",
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw ModelManifestError.unsupportedSchemaVersion
        }
        guard Self.validIdentifier(modelID, maximumLength: 128) else {
            throw ModelManifestError.invalidModelID
        }
        guard modelVersion.utf8.count <= 128, SemanticVersion(modelVersion) != nil else {
            throw ModelManifestError.invalidModelVersion
        }
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              })
        else {
            throw ModelManifestError.invalidHash
        }
        guard signature.count == 64 else {
            throw ModelManifestError.invalidSignatureEncoding
        }
        guard sizeBytes > 0, sizeBytes <= Self.maximumArtifactSizeBytes else {
            throw ModelManifestError.invalidSize
        }
        guard Self.validIdentifier(minimumCapability, maximumLength: 64) else {
            throw ModelManifestError.invalidMinimumCapability
        }
    }

    private static func validIdentifier(_ value: String, maximumLength: Int) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumLength else { return false }
        return bytes.enumerated().allSatisfy { index, byte in
            let isLetter = (65...90).contains(byte) || (97...122).contains(byte)
            let isNumber = (48...57).contains(byte)
            return isLetter
                || isNumber
                || (index > 0 && (byte == 46 || byte == 95 || byte == 45))
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

/// Production verifier for model artifacts. The Ed25519 signature covers the
/// versioned manifest payload, while size and digest are independently checked
/// against the artifact first using bounded, streaming I/O.
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
        guard publicKey.isValidSignature(manifest.signature, for: manifest.signaturePayload) else {
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
    case invalidRestoredSelection
}

struct ModelSelectionSnapshot: Equatable {
    let activeModel: InstalledModel?
    let rollbackModel: InstalledModel?
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

    var selectionSnapshot: ModelSelectionSnapshot {
        ModelSelectionSnapshot(activeModel: activeModel, rollbackModel: rollbackModel)
    }

    /// Restores an explicitly persisted active/rollback pair only after both
    /// artifacts pass the current trust-root and capability checks.
    func restoreVerifiedSelection(
        activeModel: InstalledModel?,
        rollbackModel: InstalledModel?
    ) throws {
        guard activeModel != nil || rollbackModel == nil else {
            throw ModelSelectionError.invalidRestoredSelection
        }
        if let activeModel {
            try verifyForSelection(activeModel)
        }
        if let rollbackModel {
            guard rollbackModel.artifactURL != activeModel?.artifactURL else {
                throw ModelSelectionError.invalidRestoredSelection
            }
            try verifyForSelection(rollbackModel)
        }
        self.activeModel = activeModel
        self.rollbackModel = rollbackModel
    }

    /// Used only to unwind an in-memory selection when durable state cannot be
    /// written. The snapshot was already verified before the attempted change.
    func restoreKnownVerifiedSelection(_ snapshot: ModelSelectionSnapshot) {
        activeModel = snapshot.activeModel
        rollbackModel = snapshot.rollbackModel
    }

    @discardableResult
    func activateBestVerified(from candidates: [InstalledModel]) -> InstalledModel? {
        let ordered = candidates.sorted {
            guard
                let lhs = SemanticVersion($0.manifest.modelVersion),
                let rhs = SemanticVersion($1.manifest.modelVersion)
            else { return $0.manifest.modelVersion > $1.manifest.modelVersion }
            if lhs != rhs { return lhs > rhs }
            if $0.manifest.modelVersion != $1.manifest.modelVersion {
                return $0.manifest.modelVersion > $1.manifest.modelVersion
            }
            return $0.artifactURL.lastPathComponent < $1.artifactURL.lastPathComponent
        }
        var verified: [InstalledModel] = []
        for candidate in ordered {
            do {
                try verifyForSelection(candidate)
                guard !verified.contains(where: { $0.artifactURL == candidate.artifactURL }) else {
                    continue
                }
                verified.append(candidate)
                if verified.count == 2 { break }
            } catch {
                continue
            }
        }
        activeModel = verified.first
        rollbackModel = verified.count > 1 ? verified[1] : nil
        return activeModel
    }

    @discardableResult
    func rollback() throws -> InstalledModel {
        guard let candidate = rollbackModel else {
            throw ModelSelectionError.noRollbackCandidate
        }
        try verifyForSelection(candidate)

        let previousActive = activeModel
        activeModel = candidate
        rollbackModel = previousActive
        return candidate
    }

    private func verifyForSelection(_ candidate: InstalledModel) throws {
        guard capabilities.supports(minimumCapability: candidate.manifest.minimumCapability) else {
            throw ModelSelectionError.unsupportedCapability(candidate.manifest.minimumCapability)
        }
        try verifier.verifyArtifact(at: candidate.artifactURL, against: candidate.manifest)
    }
}

private struct SemanticVersion: Comparable {
    let core: [String]
    let prerelease: [String]?

    init?(_ value: String) {
        let buildParts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        if buildParts.count == 2 {
            guard Self.validIdentifiers(buildParts[1], numericLeadingZeroAllowed: true) else {
                return nil
            }
        }

        let precedenceParts = buildParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let core = precedenceParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, core.allSatisfy(Self.validNumericIdentifier) else {
            return nil
        }
        self.core = core.map(String.init)

        if precedenceParts.count == 2 {
            guard Self.validIdentifiers(
                precedenceParts[1],
                numericLeadingZeroAllowed: false
            ) else {
                return nil
            }
            prerelease = precedenceParts[1].split(separator: ".").map(String.init)
        } else {
            prerelease = nil
        }
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.core == rhs.core && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for (left, right) in zip(lhs.core, rhs.core) where left != right {
            return Self.numericLessThan(left, right)
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case (.some(let left), .some(let right)):
            for (leftIdentifier, rightIdentifier) in zip(left, right) {
                if leftIdentifier == rightIdentifier { continue }
                let leftIsNumeric = leftIdentifier.allSatisfy(\.isNumber)
                let rightIsNumeric = rightIdentifier.allSatisfy(\.isNumber)
                switch (leftIsNumeric, rightIsNumeric) {
                case (true, true):
                    return Self.numericLessThan(leftIdentifier, rightIdentifier)
                case (true, false):
                    return true
                case (false, true):
                    return false
                case (false, false):
                    return leftIdentifier < rightIdentifier
                }
            }
            return left.count < right.count
        }
    }

    private static func validNumericIdentifier(_ value: Substring) -> Bool {
        !value.isEmpty
            && value.allSatisfy { $0.isASCII && $0.isNumber }
            && (value.count == 1 || value.first != "0")
    }

    private static func validIdentifiers(
        _ value: Substring,
        numericLeadingZeroAllowed: Bool
    ) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !identifiers.isEmpty else { return false }
        return identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty,
                  identifier.allSatisfy({ character in
                      character.isASCII && (character.isLetter || character.isNumber || character == "-")
                  })
            else {
                return false
            }
            if !numericLeadingZeroAllowed && identifier.allSatisfy(\.isNumber) {
                return identifier.count == 1 || identifier.first != "0"
            }
            return true
        }
    }

    private static func numericLessThan(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.count != rhs.count { return lhs.count < rhs.count }
        return lhs < rhs
    }
}

import CryptoKit
import XCTest
@testable import VoiceAgentBridge

final class ModelArtifactStoreTests: XCTestCase {
    func testModelManagerErrorsHaveActionableUserDescriptions() {
        let bridgedPublicKeyError: Error = LocalVoiceModelManagerError.publicKeyNotConfigured
        XCTAssertEqual(
            bridgedPublicKeyError.localizedDescription,
            "A trusted voice model has not been configured for this build."
        )
        XCTAssertEqual(
            LocalVoiceModelManagerError.publicKeyNotConfigured.errorDescription,
            "A trusted voice model has not been configured for this build."
        )
        XCTAssertEqual(
            LocalVoiceModelManagerError.invalidPublicKey.errorDescription,
            "The configured voice-model trust key is invalid."
        )
        XCTAssertEqual(
            LocalVoiceModelManagerError.modelNotInstalled.errorDescription,
            "The signed voice model is not installed."
        )
        XCTAssertEqual(
            LocalVoiceModelManagerError.invalidDownloadURL.errorDescription,
            "The voice-model download address is invalid."
        )
        XCTAssertEqual(
            LocalVoiceModelManagerError.descriptorModelIDMismatch.errorDescription,
            "The downloaded voice model does not match the required model."
        )
    }

    func testFileInstallVerifiesBeforeActivationAndPersistsManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-store-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data("signed-model-artifact".utf8)
        try bytes.write(to: source, options: .atomic)
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifest = try signedManifest(bytes: bytes, key: privateKey, version: "1.0.0")
        let verifier = try Ed25519ModelArtifactVerifier(
            publicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        let selector = RollbackSafeModelSelector(
            verifier: verifier,
            capabilities: DeclaredModelCapabilities(identifiers: ["cpu-v1"])
        )
        let store = SignedModelArtifactStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            selector: selector
        )

        let installed = try await store.install(
            SignedModelArtifactDescriptor(manifest: manifest, downloadURL: source)
        )

        XCTAssertEqual(selector.activeModel, installed)
        XCTAssertEqual(try Data(contentsOf: installed.artifactURL), bytes)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: installed.artifactURL.appendingPathExtension("manifest").path
            )
        )
    }

    func testFailedInstallDoesNotActivateCandidate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-store-failure-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data("tampered-model-artifact".utf8)
        try bytes.write(to: source, options: .atomic)
        let signingKey = Curve25519.Signing.PrivateKey()
        let wrongKey = Curve25519.Signing.PrivateKey()
        let manifest = try signedManifest(bytes: bytes, key: wrongKey, version: "1.0.0")
        let selector = RollbackSafeModelSelector(
            verifier: try Ed25519ModelArtifactVerifier(
                publicKeyRawRepresentation: signingKey.publicKey.rawRepresentation
            ),
            capabilities: DeclaredModelCapabilities(identifiers: ["cpu-v1"])
        )
        let store = SignedModelArtifactStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            selector: selector
        )

        do {
            _ = try await store.install(
                SignedModelArtifactDescriptor(manifest: manifest, downloadURL: source)
            )
            XCTFail("A signature mismatch must prevent activation")
        } catch let error as ModelArtifactVerificationError {
            XCTAssertEqual(error, .signatureMismatch)
        }
        XCTAssertNil(selector.activeModel)
        XCTAssertNil(selector.rollbackModel)
    }

    func testModelManagerRejectsNonHTTPSDescriptor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-manager-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let signingKey = Curve25519.Signing.PrivateKey()
        let manager = try LocalVoiceModelManager(
            rootURL: root,
            publicKeyBase64: signingKey.publicKey.rawRepresentation.base64EncodedString()
        )
        let manifest = try ModelManifest(
            modelID: "gemma-command",
            modelVersion: "1.0.0",
            sha256: String(repeating: "0", count: 64),
            signature: Data(repeating: 1, count: 64),
            sizeBytes: 1,
            minimumCapability: "cpu-v1"
        )
        let descriptor = ModelArtifactDescriptorResponse(
            model_id: "gemma-command",
            manifest: manifest,
            download_url: "http://localhost/model.litertlm",
            expires_at: nil
        )

        do {
            _ = try await manager.install(descriptor)
            XCTFail("The model manager must reject non-HTTPS artifact URLs")
        } catch let error as LocalVoiceModelManagerError {
            XCTAssertEqual(error, .invalidDownloadURL)
        }
    }

    func testModelDownloadBearerIsRestrictedToExactHTTPSAPIOrigin() {
        let api = URL(string: "https://staging.example.test/v1")!
        let sameOrigin = URL(string: "https://staging.example.test/v1/phone/models/gemma/artifact")!
        let otherHost = URL(string: "https://cdn.example.test/gemma.litertlm")!
        let otherPort = URL(string: "https://staging.example.test:8443/model")!
        let insecure = URL(string: "http://staging.example.test/model")!
        let userInfo = URL(string: "https://user@staging.example.test/model")!

        XCTAssertEqual(
            LocalVoiceModelManager.authorizationHeaders(
                downloadURL: sameOrigin,
                trustedAPIBaseURL: api,
                token: "access-token"
            ),
            ["Authorization": "Bearer access-token"]
        )
        for untrusted in [otherHost, otherPort, insecure, userInfo] {
            XCTAssertTrue(
                LocalVoiceModelManager.authorizationHeaders(
                    downloadURL: untrusted,
                    trustedAPIBaseURL: api,
                    token: "must-not-leak"
                ).isEmpty
            )
        }
    }

    func testAuthenticatedHTTPSDownloadStreamsAndActivatesSignedArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-manager-http-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data(repeating: 0x5a, count: 512 * 1024)
        let signingKey = Curve25519.Signing.PrivateKey()
        let manifest = try signedManifest(bytes: bytes, key: signingKey, version: "1.0.0")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let downloadURL = URL(
            string: "https://staging.example.test/v1/phone/models/gemma-command/artifact"
        )!
        ModelDownloadURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
            XCTAssertFalse(request.allowsExpensiveNetworkAccess)
            XCTAssertFalse(request.allowsConstrainedNetworkAccess)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: downloadURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/octet-stream"]
            ))
            return (response, bytes)
        }
        defer { ModelDownloadURLProtocol.handler = nil }

        let manager = try LocalVoiceModelManager(
            rootURL: root,
            publicKeyBase64: signingKey.publicKey.rawRepresentation.base64EncodedString(),
            session: session
        )
        let installed = try await manager.install(
            ModelArtifactDescriptorResponse(
                model_id: "gemma-command",
                manifest: manifest,
                download_url: downloadURL.absoluteString,
                expires_at: nil
            ),
            authorizationToken: "access-token",
            trustedAPIBaseURL: URL(string: "https://staging.example.test")!
        )

        XCTAssertEqual(try Data(contentsOf: installed.artifactURL), bytes)
        XCTAssertEqual(manager.activeModel, installed)
    }

    func testHTTPDownloadRejectsSizeMismatchBeforeActivation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-manager-size-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data(repeating: 0x2a, count: 128)
        let signingKey = Curve25519.Signing.PrivateKey()
        let manifest = try ModelManifest(
            modelID: "gemma-command",
            modelVersion: "1.0.0",
            sha256: String(repeating: "0", count: 64),
            signature: Data(repeating: 1, count: 64),
            sizeBytes: 256,
            minimumCapability: "cpu-v1"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let downloadURL = URL(string: "https://staging.example.test/model.litertlm")!
        ModelDownloadURLProtocol.handler = { _ in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: downloadURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            ))
            return (response, bytes)
        }
        defer { ModelDownloadURLProtocol.handler = nil }

        let verifier = try Ed25519ModelArtifactVerifier(
            publicKeyRawRepresentation: signingKey.publicKey.rawRepresentation
        )
        let selector = RollbackSafeModelSelector(
            verifier: verifier,
            capabilities: DeclaredModelCapabilities(identifiers: ["cpu-v1"])
        )
        let store = SignedModelArtifactStore(
            rootURL: root,
            selector: selector,
            session: session
        )

        do {
            _ = try await store.install(
                SignedModelArtifactDescriptor(manifest: manifest, downloadURL: downloadURL)
            )
            XCTFail("A truncated model download must not be activated")
        } catch let error as ModelArtifactStoreError {
            XCTAssertEqual(error, .downloadSizeMismatch(expected: 256, actual: 128))
        }
        XCTAssertNil(selector.activeModel)
    }

    func testHTTPDownloadCancelsWhenResponseExceedsSignedSize() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-manager-oversize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data(repeating: 0x2a, count: 512)
        let signingKey = Curve25519.Signing.PrivateKey()
        let manifest = try ModelManifest(
            modelID: "gemma-command",
            modelVersion: "1.0.0",
            sha256: String(repeating: "0", count: 64),
            signature: Data(repeating: 1, count: 64),
            sizeBytes: 256,
            minimumCapability: "cpu-v1"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let downloadURL = URL(string: "https://staging.example.test/oversize.litertlm")!
        ModelDownloadURLProtocol.handler = { _ in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: downloadURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "512"]
            ))
            return (response, bytes)
        }
        defer { ModelDownloadURLProtocol.handler = nil }

        let selector = RollbackSafeModelSelector(
            verifier: try Ed25519ModelArtifactVerifier(
                publicKeyRawRepresentation: signingKey.publicKey.rawRepresentation
            ),
            capabilities: DeclaredModelCapabilities(identifiers: ["cpu-v1"])
        )
        let store = SignedModelArtifactStore(rootURL: root, selector: selector, session: session)

        do {
            _ = try await store.install(SignedModelArtifactDescriptor(
                manifest: manifest,
                downloadURL: downloadURL
            ))
            XCTFail("A response larger than its signed size must be cancelled")
        } catch let error as ModelArtifactStoreError {
            XCTAssertEqual(error, .downloadSizeMismatch(expected: 256, actual: 512))
        }
        XCTAssertNil(selector.activeModel)
    }

    func testDescriptorOuterModelIDMustMatchSignedManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-manager-id-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let signingKey = Curve25519.Signing.PrivateKey()
        let manifest = try signedManifest(
            bytes: Data("model".utf8),
            key: signingKey,
            version: "1.0.0"
        )
        let manager = try LocalVoiceModelManager(
            rootURL: root,
            publicKeyBase64: signingKey.publicKey.rawRepresentation.base64EncodedString()
        )

        do {
            _ = try await manager.install(ModelArtifactDescriptorResponse(
                model_id: "different-model",
                manifest: manifest,
                download_url: "https://staging.example.test/model.litertlm",
                expires_at: nil
            ))
            XCTFail("An unsigned outer model ID must not disagree with the signed manifest")
        } catch let error as LocalVoiceModelManagerError {
            XCTAssertEqual(error, .descriptorModelIDMismatch)
        }
    }

    func testDescriptorCannotReplaceTheRequestedDefaultModelID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-manager-requested-id-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let signingKey = Curve25519.Signing.PrivateKey()
        let manifest = try signedManifest(
            bytes: Data("model".utf8),
            key: signingKey,
            version: "1.0.0",
            modelID: "other-signed-model"
        )
        let manager = try LocalVoiceModelManager(
            rootURL: root,
            publicKeyBase64: signingKey.publicKey.rawRepresentation.base64EncodedString()
        )

        do {
            _ = try await manager.install(ModelArtifactDescriptorResponse(
                model_id: "other-signed-model",
                manifest: manifest,
                download_url: "https://staging.example.test/model.litertlm",
                expires_at: nil
            ))
            XCTFail("A descriptor must not replace the app-requested model identity")
        } catch let error as LocalVoiceModelManagerError {
            XCTAssertEqual(error, .descriptorModelIDMismatch)
        }
    }

    func testRedirectPolicyKeepsAuthorizationOnExactOriginOnly() {
        let original = URL(string: "https://staging.example.test/model")!
        var sameOrigin = URLRequest(url: URL(string: "https://staging.example.test:443/next")!)
        sameOrigin.setValue(nil, forHTTPHeaderField: "Authorization")
        XCTAssertEqual(
            SignedModelArtifactStore.redirectedRequest(
                sameOrigin,
                originalURL: original,
                authorizationHeader: "Bearer secret"
            )?.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret"
        )

        let crossOrigin = URLRequest(url: URL(string: "https://cdn.example.test/model")!)
        XCTAssertNil(SignedModelArtifactStore.redirectedRequest(
            crossOrigin,
            originalURL: original,
            authorizationHeader: "Bearer secret"
        ))
        let insecure = URLRequest(url: URL(string: "http://staging.example.test/model")!)
        XCTAssertNil(SignedModelArtifactStore.redirectedRequest(
            insecure,
            originalURL: original,
            authorizationHeader: nil
        ))

        var publicRedirect = crossOrigin
        publicRedirect.setValue("must-be-removed", forHTTPHeaderField: "Authorization")
        XCTAssertNil(SignedModelArtifactStore.redirectedRequest(
            publicRedirect,
            originalURL: original,
            authorizationHeader: nil
        )?.value(forHTTPHeaderField: "Authorization"))
    }

    func testRelaunchRestoresVerifiedActiveAndRollbackModelsIncludingRollbackOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-restore-\(UUID().uuidString)", isDirectory: true)
        let installedRoot = root.appendingPathComponent("installed", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let signingKey = Curve25519.Signing.PrivateKey()
        let publicKey = signingKey.publicKey.rawRepresentation.base64EncodedString()
        let firstBytes = Data("first-signed-model".utf8)
        let secondBytes = Data("second-signed-model".utf8)
        let firstSource = root.appendingPathComponent("first.source")
        let secondSource = root.appendingPathComponent("second.source")
        try firstBytes.write(to: firstSource, options: .atomic)
        try secondBytes.write(to: secondSource, options: .atomic)
        let firstManifest = try signedManifest(
            bytes: firstBytes,
            key: signingKey,
            version: "1.0.0"
        )
        let secondManifest = try signedManifest(
            bytes: secondBytes,
            key: signingKey,
            version: "2.0.0"
        )
        let selector = RollbackSafeModelSelector(
            verifier: try Ed25519ModelArtifactVerifier(
                publicKeyRawRepresentation: signingKey.publicKey.rawRepresentation
            ),
            capabilities: DeclaredModelCapabilities(identifiers: ["cpu-v1"])
        )
        let store = SignedModelArtifactStore(rootURL: installedRoot, selector: selector)
        let first = try await store.install(SignedModelArtifactDescriptor(
            manifest: firstManifest,
            downloadURL: firstSource
        ))
        let second = try await store.install(SignedModelArtifactDescriptor(
            manifest: secondManifest,
            downloadURL: secondSource
        ))
        XCTAssertEqual(selector.activeModel, second)
        XCTAssertEqual(selector.rollbackModel, first)

        let relaunched = try LocalVoiceModelManager(
            rootURL: installedRoot,
            publicKeyBase64: publicKey
        )
        XCTAssertEqual(relaunched.activeModel?.manifest.modelVersion, "2.0.0")
        XCTAssertEqual(relaunched.rollbackModel?.manifest.modelVersion, "1.0.0")
        XCTAssertEqual(try relaunched.rollback().manifest.modelVersion, "1.0.0")

        let relaunchedAfterRollback = try LocalVoiceModelManager(
            rootURL: installedRoot,
            publicKeyBase64: publicKey
        )
        XCTAssertEqual(relaunchedAfterRollback.activeModel?.manifest.modelVersion, "1.0.0")
        XCTAssertEqual(relaunchedAfterRollback.rollbackModel?.manifest.modelVersion, "2.0.0")

        try Data("tampered-rollback".utf8).write(to: second.artifactURL, options: .atomic)
        let relaunchedAfterTampering = try LocalVoiceModelManager(
            rootURL: installedRoot,
            publicKeyBase64: publicKey
        )
        XCTAssertEqual(relaunchedAfterTampering.activeModel?.manifest.modelVersion, "1.0.0")
        XCTAssertNil(relaunchedAfterTampering.rollbackModel)
    }

    private func signedManifest(
        bytes: Data,
        key: Curve25519.Signing.PrivateKey,
        version: String,
        modelID: String = "gemma-command",
        minimumCapability: String = "cpu-v1"
    ) throws -> ModelManifest {
        let digest = Data(SHA256.hash(data: bytes))
        let digestHex = digest.map { String(format: "%02x", $0) }.joined()
        let payload = ModelManifest.signaturePayload(
            schemaVersion: ModelManifest.supportedSchemaVersion,
            modelID: modelID,
            modelVersion: version,
            sha256: digestHex,
            sizeBytes: UInt64(bytes.count),
            minimumCapability: minimumCapability
        )
        return try ModelManifest(
            modelID: modelID,
            modelVersion: version,
            sha256: digestHex,
            signature: try key.signature(for: payload),
            sizeBytes: UInt64(bytes.count),
            minimumCapability: minimumCapability
        )
    }
}

private final class ModelDownloadURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

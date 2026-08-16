import Foundation
import Combine
import Security
import UserNotifications
import UIKit

struct PendingRetryCoordinator {
    private(set) var isRunning = false
    private(set) var rerunRequested = false

    /// Starts a retry pass or records that the active pass must run once more.
    mutating func beginOrRequestRerun() -> Bool {
        guard !isRunning else {
            rerunRequested = true
            return false
        }
        isRunning = true
        return true
    }

    /// Consumes one queued pass. Requests arriving during that pass can queue
    /// the following pass without being overwritten.
    mutating func consumeRerun() -> Bool {
        let shouldRerun = rerunRequested
        rerunRequested = false
        return shouldRerun
    }

    mutating func finish() {
        isRunning = false
        rerunRequested = false
    }
}

@MainActor
final class AppStore: ObservableObject {
    private static let settingsSchemaVersion = 3
    private static let settingsSchemaKey = "vab.settingsSchemaVersion"
    private static let userIDKey = "vab.userID"
    private static let initialSessionPageSize = 20

    @Published var token: String? {
        willSet {
            guard !isApplyingAuthenticationScopeMutation,
                  newValue != token
            else { return }
            invalidateLocalVoiceWork()
        }
        didSet {
            client.token = token
            if let token {
                KeychainStore.save(token)
            } else {
                KeychainStore.delete()
            }
        }
    }
    @Published var email: String = ""
    @Published var sessions: [Session] = []
    @Published var agents: [Agent] = []
    @Published var selectedAgentId: String? = UserDefaults.standard.string(forKey: "vab.selectedAgentId")
    @Published var pushes: [DevPush] = []
    @Published var errorMessage: String?
    @Published var headphonesSimulated = false
    @Published var lastSpoken: String?
    @Published var apiBase: String = ""
    @Published var apnsToken: String?
    @Published var notificationDiagnostics: NotificationDiagnostics?
    /// In-app popup when a new knock arrives (works even if system banners are off).
    @Published var knockAlert: KnockAlert?
    @Published var notificationStatusText: String = "unknown"
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingMoreSessions = false
    @Published private(set) var hasMoreSessions = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var hasLoadedData = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var connectionState: BridgeConnectionState = .unknown
    @Published private(set) var actionInFlight: String?
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingExpiresAt: String?
    @Published private(set) var isCreatingPairingCode = false
    @Published private(set) var historyBySession: [String: [HistoryEntry]] = [:]
    @Published private(set) var messagesBySession: [String: [SessionMessage]] = [:]
    @Published private(set) var retrievalsBySession: [String: [RetrievalItem]] = [:]
    /// REST/cache snapshot only. No product UI consumes this state yet, and
    /// E5 shadow hits are never written here.
    @Published private(set) var memories: [MemoryItem] = []
    @Published private(set) var pendingOperations: [PendingOperation] = []
    @Published var pendingCommandConfirmation: PendingCommandConfirmation? = nil
    @Published private(set) var latestCommandResponse: CommandResponse? = nil
    @Published private(set) var activeCommandPresentation: BackendCommandPresentation? = nil
    @Published private(set) var undoableCommandID: String? = nil
    @Published private(set) var voiceModelStatus = "Not prepared"
    @Published private(set) var voiceController: LocalVoiceCommandController?
    /// A knock can ask the main tab to open one exact agent session.
    @Published var openSessionId: String?

    typealias MemorySnapshotLoader = () async throws -> [MemoryItem]

    let client: APIClient
    private let localStore: SQLiteStore
    private let memorySnapshotLoader: MemorySnapshotLoader
    private let memoryShadow: MemoryShadowEvaluating
    private let memoryShadowIsAllowed: @Sendable () -> Bool
    /// One shared speaker owns both backend result announcements and local
    /// clarification prompts. Push-to-talk can therefore stop any in-flight
    /// speech before opening the microphone, and scope changes cannot leave a
    /// previous account's announcement playing.
    private let commandSynthesizer: VoiceSynthesizing
    private let activeCommandCoordinator: ActiveCommandCheckpointCoordinator
    private let backgroundReconciliationDispatcher: BackgroundReconciliationDispatcher
    private lazy var eventTransport = client.makeSessionEventTransport()
    private var refreshToken: String?
    private var currentUserID: String?
    private var eventStreamTask: Task<Void, Never>?
    private var fallbackRefreshTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var foregroundReconciliationTask: Task<Void, Never>?
    private var reconciliationGeneration = 0
    private var reconciliationRequested = false
    private var reconciliationIncludeAgents = false
    private var foregroundReconciliationIncludeAgents = true
    private var foregroundNeedsReconciliation = true
    private var pendingFullSync = false
    private var nextSessionCursor: String?
    private var pendingRetryCoordinator = PendingRetryCoordinator()
    private var eventStreamGeneration = 0
    private var appliedCursor: String?
    private var knownPushIds = Set<String>()
    private var hasSeededPushIds = false
    private weak var appDelegate: AppDelegate?
    private var pendingSessionToOpen: String?
    private var voiceModelManager: LocalVoiceModelManager?
    private var voiceModelPreparationTask: Task<Void, Never>?
    private var voiceModelPreparationGeneration: UInt64?
    private var isApplyingAuthenticationScopeMutation = false
    private(set) var localVoiceScopeGeneration: UInt64 = 0

    private struct LocalVoiceWorkScope: Equatable, Sendable {
        let generation: UInt64
        let apiBaseURL: URL
        let accessToken: String
        let ownerUserID: String
        let deviceID: String
    }

    struct KnockAlert: Identifiable, Equatable {
        let id: String
        let sessionId: String?
        let title: String
        let body: String

        init(id: String, sessionId: String? = nil, title: String, body: String) {
            self.id = id
            self.sessionId = sessionId
            self.title = title
            self.body = body
        }
    }

    /// SSE is a foreground optimization over the durable REST state. A stream
    /// may open only after the current foreground reconciliation has finished.
    /// Keeping this policy pure makes lifecycle regressions easy to test.
    nonisolated static func shouldOpenEventStream(
        tokenAvailable: Bool,
        needsForegroundReconciliation: Bool,
        streamExists: Bool,
        reconciliationExists: Bool
    ) -> Bool {
        tokenAvailable &&
            !needsForegroundReconciliation &&
            !streamExists &&
            !reconciliationExists
    }

    nonisolated static func shouldForceSnapshot(
        eventName: String,
        appliedCursor: String?
    ) -> Bool {
        eventName == "sync.required"
            && (appliedCursor?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    nonisolated static func voicePreparationErrorMessage(for error: Error) -> String {
        if let modelError = error as? LocalVoiceModelManagerError {
            return modelError.userFacingDescription
        }
        return "The signed voice model could not be prepared. Please try again later."
    }

    nonisolated static func shouldFetchVoiceModel(
        forceRefresh: Bool,
        activeModelAvailable: Bool
    ) -> Bool {
        forceRefresh || !activeModelAvailable
    }

    nonisolated static func shouldPersistApiBase(
        runtimeOverride: String?,
        persistedApiBase: String?,
        resolvedApiBase: String
    ) -> Bool {
        runtimeOverride == nil
            && persistedApiBase == nil
            && !resolvedApiBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Only failures proving the POST was rejected before persistence may
    /// release the durable submission fence. Status alone is insufficient:
    /// unknown 4xx responses, timeouts, decoding failures, and conflicts keep
    /// the exact idempotent envelope for recovery.
    nonisolated static func commandSubmissionDefinitelyRejected(_ error: Error) -> Bool {
        guard let apiError = error as? APIClientError else { return false }
        switch apiError {
        case .noToken, .missingPushToken, .invalidPushToken, .invalidBaseURL:
            return true
        case let .badStatus(status, _, metadata):
            guard !metadata.retryable else { return false }
            switch (status, metadata.errorCode) {
            case (400, "validation_error"),
                 (401, "unauthorized"),
                 (404, "not_found"),
                 (422, "unsupported_intent"):
                return true
            default:
                return false
            }
        case .network, .decoding:
            return false
        }
    }

    init(
        localStore: SQLiteStore = .shared,
        commandSynthesizer: VoiceSynthesizing = SystemVoiceSynthesizer(),
        backgroundReconciliationDispatcher: BackgroundReconciliationDispatcher = .shared,
        client: APIClient = APIClient(),
        memorySnapshotLoader: MemorySnapshotLoader? = nil,
        memoryShadow: MemoryShadowEvaluating = BundledMLXMemoryShadowEvaluator(),
        memoryShadowIsAllowed: @escaping @Sendable () -> Bool = {
            let read: () -> Bool = { UIApplication.shared.applicationState == .active }
            if Thread.isMainThread {
                return read()
            }
            return DispatchQueue.main.sync(execute: read)
        }
    ) {
        self.client = client
        self.localStore = localStore
        self.memoryShadow = memoryShadow
        self.memoryShadowIsAllowed = memoryShadowIsAllowed
        self.memorySnapshotLoader = memorySnapshotLoader ?? {
            try await client.listMemories()
        }
        self.commandSynthesizer = commandSynthesizer
        self.backgroundReconciliationDispatcher = backgroundReconciliationDispatcher
        activeCommandCoordinator = ActiveCommandCheckpointCoordinator(
            store: localStore,
            synthesizer: commandSynthesizer,
            isSpeechAllowed: {
                UIApplication.shared.applicationState == .active
            }
        )
        #if DEBUG
        // UI tests run repeatedly against isolated local Workers. Keychain
        // entries survive app reinstall, so an old access/refresh token can
        // silently authenticate the test app against a different database.
        // Reset only when the UI test explicitly opts in; normal debug and
        // release launches keep their existing session and local cache.
        if ProcessInfo.processInfo.environment["KNOCK_UI_TEST_RESET_AUTH"] == "1" {
            KeychainStore.delete()
            KeychainStore.delete(account: "refresh-token")
            UserDefaults.standard.removeObject(forKey: "vab.token")
            UserDefaults.standard.removeObject(forKey: "vab.email")
            UserDefaults.standard.removeObject(forKey: "vab.apiBase")
            UserDefaults.standard.removeObject(forKey: "vab.selectedAgentId")
            UserDefaults.standard.removeObject(forKey: Self.userIDKey)
            localStore.clearUserData()
        }
        #endif
        let storedToken = KeychainStore.read() ?? UserDefaults.standard.string(forKey: "vab.token")
        let storedRefreshToken = KeychainStore.read(account: "refresh-token")
        currentUserID = UserDefaults.standard.string(forKey: Self.userIDKey)
        token = storedToken
        refreshToken = storedRefreshToken
        client.token = storedToken
        client.refreshToken = storedRefreshToken
        if let storedToken {
            KeychainStore.save(storedToken)
            UserDefaults.standard.removeObject(forKey: "vab.token")
        }
        // The old app persisted a demo email and a Mac-specific LAN address
        // without recording whether the user had configured them. Clear that
        // one-time legacy state so a stale address cannot silently win.
        if UserDefaults.standard.integer(forKey: Self.settingsSchemaKey) < Self.settingsSchemaVersion {
            if DemoConfig.isLegacyDemoEmail(UserDefaults.standard.string(forKey: "vab.email")) {
                UserDefaults.standard.removeObject(forKey: "vab.email")
            }
            #if !DEBUG
            if DemoConfig.isLegacyDevelopmentApiBase(
                UserDefaults.standard.string(forKey: "vab.apiBase"),
                requireHTTPS: true
            ) {
                UserDefaults.standard.removeObject(forKey: "vab.apiBase")
            }
            #endif
            UserDefaults.standard.set(Self.settingsSchemaVersion, forKey: Self.settingsSchemaKey)
        }

        // A Release/TestFlight update must never continue using an old HTTP,
        // localhost, or private-LAN endpoint even if the schema was already
        // marked current by an earlier build.
        #if !DEBUG
        if DemoConfig.isLegacyDevelopmentApiBase(
            UserDefaults.standard.string(forKey: "vab.apiBase"),
            requireHTTPS: true
        ) {
            UserDefaults.standard.removeObject(forKey: "vab.apiBase")
        }
        #endif

        email = UserDefaults.standard.string(forKey: "vab.email") ?? DemoConfig.email
        let runtimeApiBase = DemoConfig.runtimeApiBaseOverride()
        let persistedApiBase = UserDefaults.standard.string(forKey: "vab.apiBase")
        apiBase = runtimeApiBase ?? persistedApiBase ?? DemoConfig.defaultApiBase
        if !email.isEmpty && UserDefaults.standard.string(forKey: "vab.email") == nil {
            UserDefaults.standard.set(email, forKey: "vab.email")
        }
        // Process environment overrides belong only to this launch (UI tests,
        // diagnostics, or an explicit offline drill). Persisting one here can
        // leave the next normal launch permanently pointed at a temporary or
        // unreachable endpoint.
        if Self.shouldPersistApiBase(
            runtimeOverride: runtimeApiBase,
            persistedApiBase: persistedApiBase,
            resolvedApiBase: apiBase
        ) {
            UserDefaults.standard.set(apiBase, forKey: "vab.apiBase")
        }
        localStore.migrateLegacyState()
        appliedCursor = localStore.loadAppliedCursor()
        sessions = localStore.loadSessions()
        pushes = localStore.loadPushes()
        restoreMemorySnapshotForCurrentScope()
        pendingOperations = localStore.loadPendingOperations()
        pendingCommandConfirmation = localStore.loadPendingCommandConfirmation()
        // APIClient resolves the same runtime/persisted/bundled precedence on
        // demand. Assigning through its setter here would incorrectly persist
        // a process-only UI-test or diagnostic override.
        activeCommandCoordinator.onAnnouncementStateChange = { [weak self] error in
            guard let self else { return }
            self.publishActiveCommandState()
            if let error {
                self.errorMessage = error.localizedDescription
            }
        }
        restoreActiveCommandCheckpoint()
        backgroundReconciliationDispatcher.bind { [weak self] request in
            Task { @MainActor [weak self] in
                guard let self else {
                    request.complete(.failed)
                    return
                }
                await self.handleBackgroundReconciliation(request)
            }
        }
    }

    private var activeCommandScope: ActiveCommandScope? {
        ActiveCommandScope(backendURL: client.baseURL, ownerUserID: currentUserID)
    }

    /// Memory cache scope is origin + stable backend user only. Access and
    /// refresh tokens are intentionally absent from both this type and SQLite.
    private var memoryCacheScope: MemoryCacheScope? {
        MemoryCacheScope(apiBaseURL: client.baseURL, userID: currentUserID)
    }

    private func restoreMemorySnapshotForCurrentScope() {
        restoreMemorySnapshot(apiBaseURL: client.baseURL)
    }

    private func restoreMemorySnapshot(apiBaseURL: URL?) {
        guard let scope = MemoryCacheScope(apiBaseURL: apiBaseURL, userID: currentUserID) else {
            memories = []
            return
        }
        memories = localStore.loadMemories(in: scope)
    }

    private var localVoiceWorkScope: LocalVoiceWorkScope? {
        guard let apiBaseURL = client.baseURL,
              let accessToken = token,
              let ownerUserID = currentUserID
        else { return nil }
        return LocalVoiceWorkScope(
            generation: localVoiceScopeGeneration,
            apiBaseURL: apiBaseURL,
            accessToken: accessToken,
            ownerUserID: ownerUserID,
            deviceID: client.currentDeviceID
        )
    }

    private func localVoiceScopeIsCurrent(_ scope: LocalVoiceWorkScope) -> Bool {
        localVoiceScopeGeneration == scope.generation
            && client.baseURL == scope.apiBaseURL
            && token == scope.accessToken
            && currentUserID == scope.ownerUserID
    }

    private func makeLocalVoiceRequest(
        path: String,
        method: String,
        body: Data? = nil,
        scope: LocalVoiceWorkScope
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: scope.apiBaseURL)?.absoluteURL else {
            throw APIClientError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(scope.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(scope.deviceID, forHTTPHeaderField: "X-Device-ID")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func performLocalVoiceRequest<Response: Decodable>(
        _ request: URLRequest,
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            throw APIClientError.network(error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIClientError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.network("The server response was not HTTP.")
        }
        let status = http.statusCode
        guard (200 ..< 300).contains(status) else {
            let fallback = String(data: data, encoding: .utf8) ?? "Request failed"
            let decoded = try? JSONDecoder().decode(APIErrorBody.self, from: data)
            throw APIClientError.badStatus(
                status,
                decoded?.message ?? fallback,
                APIErrorMetadata(
                    retryable: decoded?.retryable
                        ?? (status == 408 || status == 425 || status == 429 || status >= 500),
                    retryAfter: decoded?.retry_after
                        ?? Int(http.value(forHTTPHeaderField: "Retry-After") ?? ""),
                    requestID: decoded?.request_id
                        ?? http.value(forHTTPHeaderField: "X-Request-ID"),
                    errorCode: decoded?.error
                )
            )
        }
        do {
            return try JSONDecoder().decode(responseType, from: data)
        } catch {
            throw APIClientError.decoding
        }
    }

    /// Invalidates every controller and asynchronous preparation before its
    /// authentication or backend inputs can change. Cancellation is only a
    /// signal, so every continuation also checks the monotonically increasing
    /// generation before it can publish or submit anything.
    private func invalidateLocalVoiceWork() {
        localVoiceScopeGeneration += 1
        voiceModelPreparationTask?.cancel()
        voiceModelPreparationTask = nil
        voiceModelPreparationGeneration = nil
        if let voiceController {
            voiceController.abort()
        } else {
            commandSynthesizer.stop()
        }
        voiceController = nil
        voiceModelStatus = "Not prepared"
    }

    private func restoreActiveCommandCheckpoint() {
        guard token != nil, let activeCommandScope else {
            if localStore.loadActiveCommandCheckpoint() != nil {
                do {
                    try activeCommandCoordinator.clearForScopeChange()
                } catch {
                    activeCommandCoordinator.discardInMemory()
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        do {
            activeCommandPresentation = try activeCommandCoordinator.restore(scope: activeCommandScope)
            if let durableConfirmation = activeCommandCoordinator.durablePendingConfirmation {
                pendingCommandConfirmation = durableConfirmation
                localStore.savePendingCommandConfirmation(durableConfirmation)
            }
            if let spoken = activeCommandCoordinator.lastSpoken {
                lastSpoken = spoken
            }
        } catch {
            activeCommandCoordinator.discardInMemory()
            activeCommandPresentation = nil
            errorMessage = error.localizedDescription
        }
    }

    private func publishActiveCommandState() {
        activeCommandPresentation = activeCommandCoordinator.presentation
        if let durableConfirmation = activeCommandCoordinator.durablePendingConfirmation {
            pendingCommandConfirmation = durableConfirmation
            localStore.savePendingCommandConfirmation(durableConfirmation)
        }
        if let spoken = activeCommandCoordinator.lastSpoken {
            lastSpoken = spoken
        }
    }

    private func clearActiveCommandForScopeChange() throws {
        try activeCommandCoordinator.clearForScopeChange()
        activeCommandPresentation = nil
        latestCommandResponse = nil
        undoableCommandID = nil
        pendingCommandConfirmation = nil
        localStore.clearPendingCommandConfirmation()
    }

    func markActiveCommandPresented(commandID: String, version: Int) {
        do {
            try activeCommandCoordinator.markPresented(commandID: commandID, version: version)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Delivers a canonical backend announcement that was intentionally kept
    /// silent while the app was inactive or running background reconciliation.
    func resumeDeferredCommandAnnouncement() {
        do {
            try activeCommandCoordinator.announceDeferredIfNeeded()
            publishActiveCommandState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stops both push-to-talk work and the shared backend/local speaker when
    /// the scene leaves the foreground. The direct stop is intentional: the
    /// shared synthesizer may be speaking even before a voice controller has
    /// been prepared.
    func suspendVoiceForSceneTransition() {
        voiceController?.abort()
        commandSynthesizer.stop()
    }

    func bindPush(_ appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        appDelegate.onDeviceToken = { [weak self] token in
            Task { @MainActor in
                guard let self else { return }
                self.apnsToken = token
                UserDefaults.standard.set(token, forKey: "vab.apnsToken")
                if self.token != nil {
                    do {
                        try await self.client.registerDevice(pushToken: token)
                    } catch {
                        self.errorMessage = "Push registration failed: \(error.localizedDescription)"
                    }
                }
            }
        }
        appDelegate.onAuthorizationStatus = { [weak self] status in
            Task { @MainActor in
                self?.notificationStatusText = Self.label(for: status)
            }
        }
        appDelegate.onNotificationDiagnostics = { [weak self] diagnostics in
            Task { @MainActor in
                self?.notificationDiagnostics = diagnostics
            }
        }
        appDelegate.bindNotificationTap { [weak self] sessionId in
            Task { @MainActor in
                guard let self else { return }
                self.knockAlert = nil
                await self.openSession(sessionId)
            }
        }
        if let saved = UserDefaults.standard.string(forKey: "vab.apnsToken") {
            apnsToken = saved
        }
        appDelegate.refreshAuthorizationStatus()
    }

    func requestNotificationsAgain() {
        appDelegate?.requestPushAuthorization()
        appDelegate?.refreshAuthorizationStatus()
    }

    func refreshNotificationStatus() {
        appDelegate?.refreshAuthorizationStatus()
    }

    private static func label(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not asked yet"
        case .denied: return "DENIED. Enable notifications in iPhone Settings, then open Knock Knock."
        case .authorized: return "authorized (alerts on)"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private func handleBackgroundReconciliation(
        _ request: BackgroundReconciliationRequest
    ) async {
        guard request.claim() else { return }
        guard token != nil else {
            request.complete(.noData)
            return
        }

        let previousCursor = appliedCursor
        let previousRefreshAt = lastRefreshAt
        await refresh(includeAgents: false)

        // A wake can arrive while a foreground/manual refresh is already
        // running. Wait for that owner and any queued reconciliation instead
        // of reporting success before authenticated REST has completed.
        var refreshWaitAttempts = 0
        while isRefreshing && refreshWaitAttempts < 200 {
            refreshWaitAttempts += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if let foregroundReconciliationTask {
            await foregroundReconciliationTask.value
        }
        if let reconciliationTask {
            await reconciliationTask.value
        }

        guard token != nil else {
            request.complete(.noData)
            return
        }
        let refreshCompleted = lastRefreshAt != nil && lastRefreshAt != previousRefreshAt
        request.complete(Self.backgroundFetchResult(
            authenticated: true,
            refreshCompleted: refreshCompleted,
            cursorChanged: appliedCursor != previousCursor
        ))
    }

    nonisolated static func backgroundFetchResult(
        authenticated: Bool,
        refreshCompleted: Bool,
        cursorChanged: Bool
    ) -> UIBackgroundFetchResult {
        guard authenticated else { return .noData }
        guard refreshCompleted else { return .failed }
        return cursorChanged ? .newData : .noData
    }

    @discardableResult
    func applyApiBase(persist: Bool = true) -> Bool {
        let trimmed = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        let requiresHTTPS = false
        #else
        let requiresHTTPS = true
        #endif
        guard DemoConfig.isValidApiBase(trimmed, requireHTTPS: requiresHTTPS),
              let url = URL(string: trimmed)
        else {
            errorMessage = APIClientError.invalidBaseURL.localizedDescription
            return false
        }
        let previousOrigin = ActiveCommandScope.origin(for: client.baseURL)
        let nextOrigin = ActiveCommandScope.origin(for: url)
        if client.baseURL != url {
            invalidateLocalVoiceWork()
        }
        if previousOrigin != nextOrigin {
            do {
                try clearActiveCommandForScopeChange()
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        apiBase = trimmed
        if persist {
            UserDefaults.standard.set(trimmed, forKey: "vab.apiBase")
        }
        stopEventStream()
        stopReconciliation()
        resetEventCursor()
        if persist {
            client.baseURL = url
        }
        // Switching origin must synchronously replace the visible offline
        // snapshot before this MainActor method returns.
        restoreMemorySnapshot(apiBaseURL: url)
        connectionState = .unknown
        errorMessage = nil
        return true
    }

    func dismissError() {
        errorMessage = nil
    }

    func createPairingCode() async {
        guard token != nil, !isCreatingPairingCode else { return }
        isCreatingPairingCode = true
        errorMessage = nil
        defer { isCreatingPairingCode = false }
        do {
            let response = try await client.createPairingCode()
            pairingCode = response.code
            pairingExpiresAt = response.expires_at
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Resume the foreground event stream after cold start when a JWT is already saved.
    func bootstrapIfLoggedIn() {
        guard token != nil else { return }
        startEventStream()
        Task { await refresh() }
    }

    /// Refreshes the non-UI Memory snapshot. The loader returns only after all
    /// cursor pages complete. Failure is propagated so reconciliation cannot
    /// commit a newer applied cursor over an older Memory snapshot.
    @discardableResult
    func refreshMemorySnapshot(generation: Int? = nil) async throws -> Bool {
        guard token != nil, let scope = memoryCacheScope else {
            throw CancellationError()
        }
        let snapshot = try await memorySnapshotLoader()
        guard memoryCacheScope == scope,
              token != nil,
              generation.map({ $0 == reconciliationGeneration }) ?? true,
              !Task.isCancelled
        else { throw CancellationError() }
        guard localStore.replaceMemories(snapshot, in: scope) else {
            throw APIClientError.network("Memory snapshot could not be saved atomically.")
        }
        memories = snapshot
        if memoryShadowIsAllowed() {
            memoryShadow.evaluate(
                memories: snapshot.map {
                    MemoryShadowInput(memoryID: $0.memory_id, displayText: $0.display_text)
                }
            )
        }
        return true
    }

    /// The Settings test popup proves this binary can show the knock UI.
    func showTestKnockPopup() {
        knockAlert = KnockAlert(
            id: "test-\(UUID().uuidString)",
            title: "TEST \(DemoConfig.buildLabel)",
            body: "If you see this full-screen knock, the app UI works. System banners are separate."
        )
    }

    func openSession(_ sessionId: String) async {
        guard token != nil else {
            pendingSessionToOpen = sessionId
            return
        }
        if !sessions.contains(where: { $0.session_id == sessionId }) {
            await refresh()
        }
        await loadSessionDetail(for: sessionId)
        openSessionId = sessionId
    }

    func selectAgent(_ agentId: String?) {
        selectedAgentId = agentId
        if let agentId {
            UserDefaults.standard.set(agentId, forKey: "vab.selectedAgentId")
        } else {
            UserDefaults.standard.removeObject(forKey: "vab.selectedAgentId")
        }
    }

    func loadHistory(for sessionId: String) async {
        do {
            let entries = try await client.listHistory(sessionId: sessionId)
            historyBySession[sessionId] = entries
            localStore.cacheHistory(entries, for: sessionId)
        } catch {
            // History is supplementary; an offline detail screen still shows
            // the decision itself and the local retry queue.
            let cached = localStore.loadHistory(for: sessionId)
            if !cached.isEmpty {
                historyBySession[sessionId] = cached
            } else if connectionState == .connected {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The dashboard starts with a compact summary page. Older sessions are
    /// loaded only from the full Sessions screen so cold start does not fetch
    /// an unbounded history over a mobile connection.
    func loadMoreSessions() async {
        guard token != nil,
              hasMoreSessions,
              !isLoadingMoreSessions,
              !isRefreshing,
              let cursor = nextSessionCursor,
              !cursor.isEmpty
        else { return }

        isLoadingMoreSessions = true
        defer { isLoadingMoreSessions = false }
        do {
            let page = try await client.listSessionsPage(
                before: cursor,
                limit: Self.initialSessionPageSize
            )
            let existing = Dictionary(uniqueKeysWithValues: sessions.map { ($0.session_id, $0) })
            for summary in page.sessions {
                var merged = summary
                if let detail = existing[summary.session_id] {
                    merged.mergeDetail(from: detail)
                }
                upsertSession(merged)
            }
            let candidate = page.next_cursor?.trimmingCharacters(in: .whitespacesAndNewlines)
            nextSessionCursor = candidate
            hasMoreSessions = page.has_more
                && candidate?.isEmpty == false
                && candidate != cursor
            localStore.cacheSessions(sessions)
            connectionState = .connected
            errorMessage = nil
        } catch {
            handleRefreshError(error)
        }
    }

    func loadSessionDetail(for sessionId: String) async {
        do {
            let detail = try await client.getSessionDetail(sessionId: sessionId)
            upsertSession(detail.session)
            retrievalsBySession[sessionId] = detail.retrieval_items
            localStore.cacheSessions(sessions)
            localStore.cacheRetrievals(detail.retrieval_items, for: sessionId)
        } catch {
            let cached = localStore.loadRetrievals(for: sessionId)
            if !cached.isEmpty {
                retrievalsBySession[sessionId] = cached
            } else if connectionState == .connected {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadMessages(for sessionId: String, before cursor: String? = nil) async {
        do {
            let page = try await client.listMessages(sessionId: sessionId, before: cursor)
            let existing = messagesBySession[sessionId] ?? []
            let merged = mergeMessages(existing, with: page.messages)
            messagesBySession[sessionId] = merged
            localStore.cacheMessages(page.messages, for: sessionId)
        } catch {
            let cached = localStore.loadMessages(for: sessionId)
            if !cached.isEmpty {
                messagesBySession[sessionId] = cached
            } else if connectionState == .connected {
                errorMessage = error.localizedDescription
            }
        }
    }

    func markPushRead(_ push: DevPush) async {
        do {
            let updated = try await client.markPushRead(pushId: push.push_id)
            pushes = pushes.map { $0.push_id == updated.push_id ? updated : $0 }
            localStore.cachePushes(pushes)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markAllPushesRead() async {
        do {
            _ = try await client.markAllPushesRead()
            await refresh(includeAgents: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameSession(_ session: Session, title: String?) async {
        do {
            let detail = try await client.updateSession(
                sessionId: session.session_id,
                title: title,
                archived: nil
            )
            upsertSession(detail.session)
            retrievalsBySession[session.session_id] = detail.retrieval_items
            localStore.cacheSessions(sessions)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func archiveSession(_ session: Session, archived: Bool = true) async {
        do {
            let detail = try await client.updateSession(
                sessionId: session.session_id,
                title: nil,
                archived: archived
            )
            upsertSession(detail.session)
            localStore.cacheSessions(sessions)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSession(_ session: Session) async {
        do {
            _ = try await client.deleteSession(sessionId: session.session_id)
            sessions.removeAll { $0.session_id == session.session_id }
            historyBySession[session.session_id] = nil
            messagesBySession[session.session_id] = nil
            retrievalsBySession[session.session_id] = nil
            localStore.removeSession(session.session_id)
            if openSessionId == session.session_id { openSessionId = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func searchHistory(_ query: String) async -> SearchResponse? {
        guard let query = Self.normalizedHistorySearchQuery(query) else {
            errorMessage = "Search must contain between 1 and 200 characters."
            return nil
        }
        do {
            return try await client.search(query: query)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    nonisolated static func normalizedHistorySearchQuery(_ query: String) -> String? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 200 else { return nil }
        return normalized
    }

    func exportSession(_ sessionId: String) async -> SessionExportResponse? {
        do {
            return try await client.exportSession(sessionId: sessionId)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func upsertSession(_ session: Session) {
        sessions.removeAll { $0.session_id == session.session_id }
        sessions.append(session)
        sessions.sort { lhs, rhs in
            if lhs.needsUser != rhs.needsUser { return lhs.needsUser && !rhs.needsUser }
            return lhs.updated_at > rhs.updated_at
        }
    }

    private func mergeMessages(
        _ existing: [SessionMessage],
        with incoming: [SessionMessage]
    ) -> [SessionMessage] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.message_id, $0) })
        for message in incoming {
            byID[message.message_id] = message
        }
        return byID.values.sorted {
            if $0.created_at != $1.created_at { return $0.created_at < $1.created_at }
            return $0.message_id < $1.message_id
        }
    }

    private func finishAuthentication(_ auth: AuthResponse) async throws {
        try applyAuth(auth)
        // Restore the backend-owned inbox before attempting APNs
        // registration. A physical device can take much longer to register
        // while its network route is settling; that must never leave an
        // authenticated user looking at an empty workspace.
        resetEventCursor()
        await refresh()
        // `refresh()` starts SSE after a successful reconciliation. Calling
        // this idempotent wrapper as well preserves the fallback refresh loop
        // when that first REST attempt fails because the route is still
        // settling immediately after authentication.
        startEventStream()

        // Device registration enables system delivery, but it must not block
        // the in-app decision surface. Simulators can lack a real APNs
        // entitlement, and a temporary registration outage should still let
        // the user poll the exact session inbox.
        do {
            try await client.registerDevice(pushToken: apnsToken)
        } catch {
            print("[push] device registration deferred: \(error.localizedDescription)")
        }
        if let pendingSessionToOpen {
            self.pendingSessionToOpen = nil
            await openSession(pendingSessionToOpen)
        }
    }

    func login(password: String) async {
        guard !isAuthenticating else { return }
        errorMessage = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let auth = try await client.login(email: email, password: password)
            try await finishAuthentication(auth)
        } catch let loginError as APIClientError {
            if case .badStatus(401, _, _) = loginError {
                errorMessage = "邮箱或密码不正确；如果你还没有账户，请切换到创建账户。"
            } else {
                errorMessage = loginError.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func register(password: String) async {
        guard !isAuthenticating else { return }
        errorMessage = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let auth = try await client.register(email: email, password: password)
            try await finishAuthentication(auth)
        } catch let registerError as APIClientError {
            if case .badStatus(409, _, _) = registerError {
                errorMessage = "这个邮箱已经注册，请切换到登录。"
            } else {
                errorMessage = registerError.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyAuth(_ auth: AuthResponse) throws {
        let accountWillChange = currentUserID != auth.user_id
        let accessTokenWillChange = token != auth.token
        if accountWillChange || accessTokenWillChange {
            invalidateLocalVoiceWork()
        }
        if currentUserID != nil, accountWillChange {
            try clearActiveCommandForScopeChange()
        }
        isApplyingAuthenticationScopeMutation = true
        currentUserID = auth.user_id
        UserDefaults.standard.set(auth.user_id, forKey: Self.userIDKey)
        if accountWillChange {
            restoreMemorySnapshotForCurrentScope()
        }
        token = auth.token
        isApplyingAuthenticationScopeMutation = false
        if let nextRefresh = auth.refresh_token {
            refreshToken = nextRefresh
            client.refreshToken = nextRefresh
            KeychainStore.save(nextRefresh, account: "refresh-token")
        }
        UserDefaults.standard.set(email, forKey: "vab.email")
    }

    /// Selects the approved local command runtime. iPhone 13 Pro-class devices
    /// use the fail-closed deterministic parser; other supported devices fetch
    /// Gemma on demand and never activate it until the pinned public key and
    /// native runtime probe both succeed.
    func prepareLocalVoiceModel(forceRefresh: Bool = false) async {
        guard let scope = localVoiceWorkScope else {
            voiceModelStatus = "Sign in before preparing voice"
            return
        }
        if let voiceModelPreparationTask,
           voiceModelPreparationGeneration == scope.generation
        {
            await voiceModelPreparationTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLocalVoiceModelPreparation(
                forceRefresh: forceRefresh,
                scope: scope
            )
        }
        voiceModelPreparationTask = task
        voiceModelPreparationGeneration = scope.generation
        await task.value
        guard voiceModelPreparationGeneration == scope.generation else { return }
        voiceModelPreparationTask = nil
        voiceModelPreparationGeneration = nil
    }

    private func performLocalVoiceModelPreparation(
        forceRefresh: Bool,
        scope: LocalVoiceWorkScope
    ) async {
        guard localVoiceScopeIsCurrent(scope) else { return }
        if LocalVoiceRuntimePolicy.strategy() == .deterministicParser {
            let previousController = voiceController
            let replacement = makeVoiceController(
                generator: DeterministicCommandGenerator(deviceID: scope.deviceID),
                scope: scope
            )
            guard localVoiceScopeIsCurrent(scope) else {
                replacement.abort()
                return
            }
            previousController?.abort()
            voiceController = replacement
            voiceModelStatus = "Ready · Safe parser"
            return
        }
        voiceModelStatus = "Preparing on-device voice model…"
        let previousController = voiceController
        var modelBeforeAttempt: InstalledModel?
        do {
            let manager: LocalVoiceModelManager
            if let existing = voiceModelManager {
                manager = existing
            } else {
                manager = try LocalVoiceModelManager()
            }
            guard localVoiceScopeIsCurrent(scope) else { throw CancellationError() }
            voiceModelManager = manager
            let previousModel = manager.activeModel
            modelBeforeAttempt = previousModel
            if Self.shouldFetchVoiceModel(
                forceRefresh: forceRefresh,
                activeModelAvailable: previousModel != nil
            ) {
                let descriptorRequest = try makeLocalVoiceRequest(
                    path: "/v1/phone/models/\(LocalVoiceModelManager.defaultModelID)",
                    method: "GET",
                    scope: scope
                )
                let descriptor: ModelArtifactDescriptorResponse = try await performLocalVoiceRequest(
                    descriptorRequest
                )
                try Task.checkCancellation()
                guard localVoiceScopeIsCurrent(scope) else { throw CancellationError() }
                _ = try await manager.install(
                    descriptor,
                    authorizationToken: scope.accessToken,
                    trustedAPIBaseURL: scope.apiBaseURL
                )
            }
            try Task.checkCancellation()
            guard localVoiceScopeIsCurrent(scope) else { throw CancellationError() }
            // Signature/hash verification proves provenance, not that the
            // container can actually initialize on this device. Probe before
            // replacing the controller or reporting Ready.
            try await manager.validateActiveModelRuntime()
            try Task.checkCancellation()
            guard localVoiceScopeIsCurrent(scope) else { throw CancellationError() }
            let replacement = try makeVoiceController(using: manager, scope: scope)
            guard localVoiceScopeIsCurrent(scope) else {
                replacement.abort()
                throw CancellationError()
            }
            previousController?.abort()
            voiceController = replacement
            if let model = manager.activeModel {
                voiceModelStatus = "Ready · Gemma \(model.manifest.modelVersion)"
            } else {
                voiceModelStatus = "Model not installed"
            }
        } catch {
            if error is CancellationError || !localVoiceScopeIsCurrent(scope) { return }
            let message = Self.voicePreparationErrorMessage(for: error)
            if let manager = voiceModelManager,
               let previousController,
               let previousModel = modelBeforeAttempt
            {
                // A download/descriptor failure must not disable the last
                // verified runtime. If a newly activated artifact cannot open,
                // roll back to the persisted predecessor before retaining the
                // old controller.
                var previousSelectionRestored = manager.activeModel == previousModel
                if !previousSelectionRestored,
                   manager.rollbackModel == previousModel,
                   (try? manager.rejectActiveModelAfterRuntimeFailure(
                       restoring: previousModel
                   )) != nil
                {
                    previousSelectionRestored = manager.activeModel == previousModel
                }
                if previousSelectionRestored {
                    voiceController = previousController
                    voiceModelStatus = "Ready · Gemma \(previousModel.manifest.modelVersion) · Update failed"
                    errorMessage = "Voice model update failed; the previous verified model is still active. \(message)"
                } else {
                    voiceController = nil
                    voiceModelStatus = "Unavailable · Update and rollback failed"
                    errorMessage = "The voice model update failed and the previous verified model could not be restored. \(message)"
                }
            } else {
                // A first installation has no predecessor to roll back to.
                // Quarantine an unloadable artifact so relaunch cannot select
                // it again merely because its signature remains valid.
                if let manager = voiceModelManager,
                   error as? LocalVoiceAdapterError == .gemmaRuntimeInitializationFailed
                {
                    try? manager.rejectActiveModelAfterRuntimeFailure(restoring: nil)
                }
                voiceController = nil
                voiceModelStatus = "Unavailable · \(message)"
                errorMessage = "On-device voice is not ready: \(message)"
            }
        }
    }

    private func makeVoiceController(
        using manager: LocalVoiceModelManager,
        scope: LocalVoiceWorkScope
    ) throws -> LocalVoiceCommandController {
        let generator = try manager.makeCommandGenerator(deviceID: scope.deviceID)
        return makeVoiceController(generator: generator, scope: scope)
    }

    private func makeVoiceController(
        generator: LocalCommandGenerating,
        scope: LocalVoiceWorkScope
    ) -> LocalVoiceCommandController {
        return LocalVoiceCommandController(
            generator: generator,
            submit: { [weak self] envelope in
                guard let self else {
                    throw APIClientError.network("Knock Knock is no longer available")
                }
                return try await self.submitLocalCommand(envelope, scope: scope)
            },
            synthesizer: commandSynthesizer,
            operationIsAllowed: { [weak self] in
                self?.localVoiceScopeIsCurrent(scope) == true
            }
        )
    }

    private func submitLocalCommand(
        _ envelope: CommandEnvelope,
        scope: LocalVoiceWorkScope
    ) async throws -> CommandResponse {
        try Task.checkCancellation()
        guard localVoiceScopeIsCurrent(scope),
              let activeCommandScope,
              activeCommandScope.backendOrigin == ActiveCommandScope.origin(for: scope.apiBaseURL),
              activeCommandScope.ownerUserID == scope.ownerUserID
        else { throw CancellationError() }
        let application: ActiveCommandApplication
        do {
            application = try await activeCommandCoordinator.submit(
                envelope: envelope,
                scope: activeCommandScope,
                onBegan: { [weak self] in
                    self?.publishActiveCommandState()
                }
            ) { [weak self] canonicalEnvelope in
                guard let self else { throw CancellationError() }
                try Task.checkCancellation()
                guard self.localVoiceScopeIsCurrent(scope) else {
                    throw CancellationError()
                }
                let request = try self.makeLocalVoiceRequest(
                    path: "/v1/phone/commands",
                    method: "POST",
                    body: JSONEncoder().encode(canonicalEnvelope),
                    scope: scope
                )
                let response: CommandResponse = try await self.performLocalVoiceRequest(request)
                try Task.checkCancellation()
                guard self.localVoiceScopeIsCurrent(scope) else {
                    throw CancellationError()
                }
                return response
            }
        } catch {
            if Self.commandSubmissionDefinitelyRejected(error) {
                try activeCommandCoordinator.abandonUnacknowledgedSubmission(
                    expectedCommandID: envelope.commandID
                )
                publishActiveCommandState()
            }
            throw error
        }
        try Task.checkCancellation()
        guard localVoiceScopeIsCurrent(scope) else { throw CancellationError() }
        consumeCommandApplication(application)

        // Read back the server-owned state before presenting it. The create
        // response is useful for degraded connectivity, but GET is the
        // canonical source for risk, confirmation, and lifecycle state.
        let canonical: CommandResponse
        do {
            let request = try makeLocalVoiceRequest(
                path: "/v1/phone/commands/\(envelope.commandID)",
                method: "GET",
                scope: scope
            )
            canonical = try await performLocalVoiceRequest(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return application.response
        }
        try Task.checkCancellation()
        guard localVoiceScopeIsCurrent(scope) else { throw CancellationError() }
        if let canonicalApplication = try activeCommandCoordinator.accept(
            response: canonical,
            expectedCommandID: envelope.commandID
        ) {
            consumeCommandApplication(canonicalApplication)
        }
        return canonical
    }

    @discardableResult
    private func handleCommandResponse(
        _ response: CommandResponse,
        expectedCommandID: String
    ) throws -> Bool {
        guard let application = try activeCommandCoordinator.accept(
            response: response,
            expectedCommandID: expectedCommandID
        ) else { return false }
        consumeCommandApplication(application)
        return true
    }

    /// Consumes only responses already fenced by `ActiveCommandCheckpointCoordinator`.
    /// Internal visibility keeps the server-owned UI transition deterministic in tests.
    func consumeCommandApplication(_ application: ActiveCommandApplication) {
        publishActiveCommandState()
        let response = application.response
        // Eligibility can expire without a command version change, so consume
        // this field for idempotent reconciliation responses as well as newer
        // lifecycle versions. A missing, null, or malformed value clears Undo.
        undoableCommandID = response.serverAuthorizedUndoCommandID
        guard application.outcome == .applied else { return }
        latestCommandResponse = response
        if response.state != "awaiting_confirmation",
           pendingCommandConfirmation?.command_id == response.command_id
        {
            pendingCommandConfirmation = nil
            localStore.clearPendingCommandConfirmation()
        }
        guard response.state == "awaiting_confirmation" else { return }
        guard let action = response.action,
              action.confirm_required
        else {
            // Never infer a confirmation title or risk from the local intent.
            // An awaiting state without backend metadata is fail-closed.
            errorMessage = "This command needs server confirmation metadata before it can run."
            return
        }
        let token = activeCommandCoordinator.durablePendingConfirmation
            .flatMap { $0.command_id == response.command_id ? $0.confirmation_token : nil }
        guard let token else {
            // GET intentionally does not repeat a one-time token. If the
            // backend version advanced because another replay rotated the
            // authority, discard any older UI copy rather than offering a
            // token which can no longer confirm this command.
            pendingCommandConfirmation = nil
            localStore.clearPendingCommandConfirmation()
            errorMessage = "This command needs a fresh confirmation token before it can run."
            return
        }
        let confirmation = PendingCommandConfirmation(
            command_id: response.command_id,
            confirmation_token: token,
            title: action.title,
            risk: action.risk,
            confirm_required: action.confirm_required,
            reversible: action.reversible
        )
        pendingCommandConfirmation = confirmation
        localStore.savePendingCommandConfirmation(confirmation)
    }

    func deferPendingCommandConfirmation() {
        // Keep the token in SQLite. The command remains awaiting confirmation
        // and will be restored on the next app launch.
        pendingCommandConfirmation = nil
    }

    func confirmPendingCommand() async {
        guard let confirmation = pendingCommandConfirmation else { return }
        errorMessage = nil
        do {
            let response = try await client.confirmCommand(
                commandID: confirmation.command_id,
                confirmationToken: confirmation.confirmation_token
            )
            let canonical = (try? await client.getCommand(commandID: confirmation.command_id)) ?? response
            let accepted = try handleCommandResponse(
                canonical,
                expectedCommandID: confirmation.command_id
            )
            if accepted, canonical.state != "awaiting_confirmation" {
                pendingCommandConfirmation = nil
                localStore.clearPendingCommandConfirmation()
                await refresh()
            }
        } catch {
            errorMessage = "Confirmation was not sent. (\(error.localizedDescription))"
        }
    }

    func cancelPendingCommand() async {
        guard let confirmation = pendingCommandConfirmation else { return }
        errorMessage = nil
        do {
            let response = try await client.cancelCommand(commandID: confirmation.command_id)
            let canonical = (try? await client.getCommand(commandID: confirmation.command_id)) ?? response
            if try handleCommandResponse(
                canonical,
                expectedCommandID: confirmation.command_id
            ) {
                pendingCommandConfirmation = nil
                localStore.clearPendingCommandConfirmation()
                await refresh()
            }
        } catch {
            errorMessage = "The command was not cancelled. (\(error.localizedDescription))"
        }
    }

    func undoCommand(commandID: String) async {
        errorMessage = nil
        do {
            let response = try await client.undoCommand(commandID: commandID)
            let canonical = (try? await client.getCommand(commandID: commandID)) ?? response
            if try handleCommandResponse(canonical, expectedCommandID: commandID) {
                await refresh()
            }
        } catch {
            errorMessage = "Undo was not completed. (\(error.localizedDescription))"
        }
    }

    func logout() {
        invalidateLocalVoiceWork()
        if let refreshToken {
            let client = self.client
            Task { try? await client.logout(refreshToken: refreshToken) }
        }
        stopEventStream()
        stopReconciliation()
        isApplyingAuthenticationScopeMutation = true
        token = nil
        refreshToken = nil
        currentUserID = nil
        isApplyingAuthenticationScopeMutation = false
        client.refreshToken = nil
        KeychainStore.delete(account: "refresh-token")
        UserDefaults.standard.removeObject(forKey: Self.userIDKey)
        sessions = []
        nextSessionCursor = nil
        hasMoreSessions = false
        isLoadingMoreSessions = false
        agents = []
        pushes = []
        hasLoadedData = false
        lastRefreshAt = nil
        connectionState = .unknown
        actionInFlight = nil
        pairingCode = nil
        pairingExpiresAt = nil
        openSessionId = nil
        historyBySession = [:]
        messagesBySession = [:]
        retrievalsBySession = [:]
        memories = []
        memoryShadow.cancel()
        MemoryShadowCacheFiles.removeReports()
        pendingOperations = []
        pendingCommandConfirmation = nil
        latestCommandResponse = nil
        activeCommandPresentation = nil
        undoableCommandID = nil
        localStore.clearUserData()
        activeCommandCoordinator.discardInMemory()
        lastSpoken = nil
        pendingSessionToOpen = nil
        knownPushIds = []
        hasSeededPushIds = false
        knockAlert = nil
        resetEventCursor()
    }

    /// Starts the foreground-only realtime transport only after a durable REST
    /// reconciliation has completed. This keeps the current Settings/pairing
    /// shell unchanged while making lifecycle ordering explicit.
    func startEventStream() {
        guard token != nil, eventStreamTask == nil else { return }
        stopFallbackRefresh()
        foregroundNeedsReconciliation = true
        foregroundReconciliationIncludeAgents = true
        guard foregroundReconciliationTask == nil else { return }

        let generation = reconciliationGeneration
        foregroundReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = await self.runForegroundReconciliation(generation: generation)
            guard self.reconciliationGeneration == generation,
                  self.token != nil
            else { return }
            self.foregroundReconciliationTask = nil
            if ready {
                self.startEventStreamNow()
            } else {
                // Keep a foreground retry path alive when the initial REST
                // reconciliation cannot reach the bridge. The next successful
                // refresh starts SSE through the same reconciliation gate.
                self.startFallbackRefresh()
            }
        }
    }

    /// Compatibility wrapper for older views/tests. The app no longer polls
    /// every two seconds; this now starts SSE instead.
    func startPolling() {
        startEventStream()
    }

    private func startEventStreamNow() {
        guard Self.shouldOpenEventStream(
            tokenAvailable: token != nil,
            needsForegroundReconciliation: foregroundNeedsReconciliation,
            streamExists: eventStreamTask != nil,
            reconciliationExists: foregroundReconciliationTask != nil
        ) else { return }
        stopFallbackRefresh()
        eventStreamGeneration += 1
        let generation = eventStreamGeneration
        eventStreamTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.eventStreamGeneration == generation {
                    self.eventStreamTask = nil
                }
            }
            await self?.runEventStream(generation: generation)
        }
    }

    /// Stop the foreground stream when iOS moves the app into the background.
    /// APNs remains responsible for waking the user while the app is suspended.
    func stopEventStream() {
        eventStreamGeneration += 1
        eventStreamTask?.cancel()
        eventStreamTask = nil
        foregroundReconciliationTask?.cancel()
        foregroundReconciliationTask = nil
        stopFallbackRefresh()
        stopReconciliation()
        foregroundNeedsReconciliation = true
    }

    /// A temporary, low-frequency safety net for an unavailable SSE service.
    /// It is only active while the app is foregrounded and never replaces the
    /// normal event-driven path.
    private func startFallbackRefresh() {
        guard token != nil, fallbackRefreshTask == nil else { return }
        fallbackRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func stopFallbackRefresh() {
        fallbackRefreshTask?.cancel()
        fallbackRefreshTask = nil
    }

    private func resetEventCursor() {
        appliedCursor = nil
        // A new authentication scope has no trustworthy incremental cursor.
        // Load one authoritative REST snapshot first instead of replaying the
        // account's entire phone_changes history before showing the inbox.
        pendingFullSync = true
        foregroundNeedsReconciliation = true
        localStore.resetSyncState(clearPendingEvents: true)
    }

    private func stopReconciliation() {
        reconciliationGeneration += 1
        reconciliationTask?.cancel()
        reconciliationTask = nil
        reconciliationRequested = false
        reconciliationIncludeAgents = false
        pendingFullSync = false
    }

    private func runEventStream(generation: Int) async {
        var retrySeconds: UInt64 = 1
        while !Task.isCancelled {
            guard token != nil, eventStreamGeneration == generation else { return }

            if foregroundNeedsReconciliation {
                guard await reconcileBeforeReconnect(generation: generation) else {
                    let delay = min(retrySeconds, 30)
                    retrySeconds = min(retrySeconds * 2, 30)
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    continue
                }
            }

            do {
                let events = try await eventTransport.stream(since: appliedCursor)
                stopFallbackRefresh()
                retrySeconds = 1
                for try await event in events {
                    guard !Task.isCancelled,
                          eventStreamGeneration == generation
                    else { return }
                    handleServerSentEvent(event)
                }
            } catch {
                if Task.isCancelled || eventStreamGeneration != generation { return }
                if Self.isUnauthorized(error), await renewAccessToken() {
                    foregroundNeedsReconciliation = true
                    retrySeconds = 1
                    continue
                }
                if case let APIClientError.badStatus(_, _, metadata) = error,
                   let retryAfter = metadata.retryAfter,
                   retryAfter > 0
                {
                    retrySeconds = min(UInt64(retryAfter), 30)
                    if let requestID = metadata.requestID {
                        print("[sse] retryable request=\(requestID) retry_after=\(retryAfter)")
                    }
                }
                connectionState = .unavailable
                startFallbackRefresh()
                print("[sse] \(error.localizedDescription)")
            }

            guard !Task.isCancelled, eventStreamGeneration == generation else { return }
            // A clean EOF is also a reconnect boundary. Reconcile the durable
            // REST state before asking SSE for another stream.
            foregroundNeedsReconciliation = true
            guard await reconcileBeforeReconnect(generation: generation) else {
                continue
            }
            let delay = min(retrySeconds, 30)
            retrySeconds = min(retrySeconds * 2, 30)
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        }
    }

    private func handleServerSentEvent(_ event: RealtimeEvent<SessionInvalidation>) {
        if let eventID = event.id, !eventID.isEmpty {
            _ = localStore.recordPendingSyncEvent(eventID: eventID, eventName: event.name)
        }
        foregroundNeedsReconciliation = true
        if ["gap", "cursor_gap", "full_sync_required"].contains(event.payload.reason?.lowercased()) {
            pendingFullSync = true
        }

        switch event.name {
        case "sync.required":
            // The server attaches its current user-scoped head cursor to the
            // initial invalidation. Snapshot first, then atomically commit that
            // cursor so a new device never replays the full historical log.
            pendingFullSync = pendingFullSync || Self.shouldForceSnapshot(
                eventName: event.name,
                appliedCursor: appliedCursor
            )
            scheduleReconciliation(includeAgents: true)
        case "session.updated":
            // A session update cannot change the agent list. Keep the push
            // inbox reconciliation, but avoid fetching /v1/agents for every
            // progress event.
            scheduleReconciliation(includeAgents: false)
        case "message.created", "command.updated", "push.updated":
            scheduleReconciliation(includeAgents: false)
        default:
            // Unknown invalidations still need a snapshot pass. The event
            // name is only a hint; REST remains the source of truth.
            scheduleReconciliation(includeAgents: false)
        }
    }

    /// Serializes REST reconciliation requests. A burst of SSE invalidations
    /// only schedules another pass after the current pass finishes, so an
    /// event cannot be dropped behind the old `isRefreshing` guard.
    private func scheduleReconciliation(includeAgents: Bool) {
        reconciliationRequested = true
        reconciliationIncludeAgents = reconciliationIncludeAgents || includeAgents
        guard foregroundReconciliationTask == nil, reconciliationTask == nil else { return }
        let generation = reconciliationGeneration
        reconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.reconciliationGeneration == generation {
                    self.reconciliationTask = nil
                }
            }
            while !Task.isCancelled,
                  self.token != nil,
                  self.reconciliationGeneration == generation
            {
                self.reconciliationRequested = false
                let includeAgents = self.reconciliationIncludeAgents
                self.reconciliationIncludeAgents = false
                let forceFullSync = self.pendingFullSync
                self.pendingFullSync = false
                do {
                    try await self.performReconciliationPass(
                        after: self.appliedCursor,
                        includeAgents: includeAgents,
                        forceFullSync: forceFullSync,
                        generation: generation
                    )
                    guard self.reconciliationGeneration == generation,
                          self.token != nil
                    else { return }
                    if !self.reconciliationRequested,
                       self.localStore.loadPendingSyncEvents().isEmpty
                    {
                        self.foregroundNeedsReconciliation = false
                        break
                    }
                    self.reconciliationRequested = true
                } catch {
                    if Self.isUnauthorized(error), await self.renewAccessToken() {
                        self.reconciliationRequested = true
                        continue
                    }
                    self.handleRefreshError(error)
                    break
                }
            }
        }
    }

    private struct ReconciliationResult {
        let cursor: String?
        let resetCursor: Bool
        let memoryTombstoneIDs: Set<String>
    }

    private func performReconciliationPass(
        after cursor: String?,
        includeAgents: Bool,
        forceFullSync: Bool,
        generation: Int
    ) async throws {
        let queuedEvents = localStore.loadPendingSyncEvents()
        let consumedEventIDs = Set(queuedEvents.map(\.event_id))
        let fallbackCursor = queuedEvents.last?.event_id
        let result = try await reconcile(
            after: cursor,
            fallbackCursor: fallbackCursor,
            includeAgents: includeAgents,
            forceFullSync: forceFullSync,
            generation: generation
        )
        guard reconciliationGeneration == generation, token != nil else {
            throw CancellationError()
        }
        for memoryID in result.memoryTombstoneIDs.sorted() {
            guard removeLocalMemory(memoryID) else {
                throw APIClientError.network("Memory tombstone could not be saved locally.")
            }
        }
        guard localStore.commitReconciliation(
            cursor: result.cursor,
            resetCursor: result.resetCursor,
            consumedEventIDs: consumedEventIDs
        ) else {
            throw APIClientError.network("Local sync state could not be committed.")
        }
        if result.resetCursor {
            appliedCursor = nil
        } else if let resultCursor = result.cursor, !resultCursor.isEmpty {
            appliedCursor = resultCursor
        } else {
            appliedCursor = localStore.loadAppliedCursor()
        }
    }

    private func reconcile(
        after cursor: String?,
        fallbackCursor: String?,
        includeAgents: Bool,
        forceFullSync: Bool,
        generation: Int
    ) async throws -> ReconciliationResult {
        if forceFullSync {
            clearInMemoryDetailCaches()
            localStore.clearDetailCaches()
            try await loadRemoteState(includeAgents: includeAgents, generation: generation)
            guard reconciliationGeneration == generation, token != nil else {
                throw CancellationError()
            }
            return ReconciliationResult(
                cursor: fallbackCursor ?? cursor,
                resetCursor: false,
                memoryTombstoneIDs: []
            )
        }

        var nextCursor = cursor
        var memoryTombstoneIDs = Set<String>()
        do {
            var previousCursor = nextCursor
            while true {
                try Task.checkCancellation()
                let response = try await client.sync(after: nextCursor)
                guard reconciliationGeneration == generation, token != nil else {
                    throw CancellationError()
                }
                if response.requiresFullSync {
                    clearInMemoryDetailCaches()
                    localStore.clearDetailCaches()
                    try await loadRemoteState(includeAgents: includeAgents, generation: generation)
                    guard reconciliationGeneration == generation, token != nil else {
                        throw CancellationError()
                    }
                    let responseCursor = response.effectiveNextCursor
                    return ReconciliationResult(
                        cursor: responseCursor.isEmpty ? (fallbackCursor ?? nextCursor) : responseCursor,
                        resetCursor: false,
                        memoryTombstoneIDs: memoryTombstoneIDs
                    )
                }
                for change in response.changes where change.deleted_at != nil {
                    switch change.entity_type {
                    case "session":
                        removeLocalSession(change.entity_id)
                    case "message":
                        removeLocalMessage(change.entity_id, sessionID: change.session_id)
                    case "retrieval":
                        removeLocalRetrieval(change.entity_id, sessionID: change.session_id)
                    case "memory":
                        // Stage Memory tombstones until the complete REST
                        // snapshot has been atomically replaced. A later page
                        // failure must preserve the old cache and old cursor.
                        memoryTombstoneIDs.insert(change.entity_id)
                    default:
                        break
                    }
                }
                let responseCursor = response.effectiveNextCursor
                if !responseCursor.isEmpty {
                    nextCursor = responseCursor
                }
                guard response.has_more,
                      !responseCursor.isEmpty,
                      responseCursor != previousCursor
                else { break }
                previousCursor = responseCursor
            }
        } catch APIClientError.badStatus(404, _, _) {
            // Phase 0/older backends have no durable sync endpoint yet. A
            // complete REST snapshot is still authoritative and safe.
            try await loadRemoteState(includeAgents: includeAgents, generation: generation)
            guard reconciliationGeneration == generation, token != nil else {
                throw CancellationError()
            }
            return ReconciliationResult(
                cursor: fallbackCursor ?? nextCursor,
                resetCursor: false,
                memoryTombstoneIDs: memoryTombstoneIDs
            )
        } catch let APIClientError.badStatus(code, _, _) where [400, 409, 410].contains(code) {
            // A cursor can be malformed, expired, or outside the server's
            // retention window. Reset it and establish a fresh REST snapshot;
            // otherwise SSE would reconnect forever with the same bad cursor.
            clearInMemoryDetailCaches()
            localStore.clearDetailCaches()
            try await loadRemoteState(includeAgents: includeAgents, generation: generation)
            guard reconciliationGeneration == generation, token != nil else {
                throw CancellationError()
            }
            return ReconciliationResult(
                cursor: nil,
                resetCursor: true,
                memoryTombstoneIDs: memoryTombstoneIDs
            )
        }
        try await loadRemoteState(includeAgents: includeAgents, generation: generation)
        guard reconciliationGeneration == generation, token != nil else {
            throw CancellationError()
        }
        return ReconciliationResult(
            cursor: nextCursor ?? fallbackCursor,
            resetCursor: false,
            memoryTombstoneIDs: memoryTombstoneIDs
        )
    }

    private func reconcileBeforeReconnect(generation: Int) async -> Bool {
        guard token != nil, eventStreamGeneration == generation else { return false }
        if let foregroundReconciliationTask {
            await foregroundReconciliationTask.value
        }
        if let reconciliationTask {
            await reconciliationTask.value
        }
        var renewed = false
        while !Task.isCancelled,
              token != nil,
              eventStreamGeneration == generation
        {
            reconciliationRequested = false
            let includeAgents = reconciliationIncludeAgents
            reconciliationIncludeAgents = false
            let forceFullSync = pendingFullSync
            pendingFullSync = false
            do {
                try await performReconciliationPass(
                    after: appliedCursor,
                    includeAgents: includeAgents,
                    forceFullSync: forceFullSync,
                    generation: reconciliationGeneration
                )
                await retryPendingOperations(generation: reconciliationGeneration)
                if !reconciliationRequested,
                   localStore.loadPendingSyncEvents().isEmpty
                {
                    foregroundNeedsReconciliation = false
                    return true
                }
            } catch {
                if !renewed, Self.isUnauthorized(error), await renewAccessToken() {
                    renewed = true
                    reconciliationRequested = true
                    continue
                }
                handleRefreshError(error)
                return false
            }
        }
        return false
    }

    private func runForegroundReconciliation(generation: Int) async -> Bool {
        guard token != nil else { return false }
        var renewed = false
        while !Task.isCancelled,
              token != nil,
              reconciliationGeneration == generation
        {
            reconciliationRequested = false
            let includeAgents = foregroundReconciliationIncludeAgents || reconciliationIncludeAgents
            foregroundReconciliationIncludeAgents = false
            reconciliationIncludeAgents = false
            let forceFullSync = pendingFullSync
            pendingFullSync = false
            do {
                try await performReconciliationPass(
                    after: appliedCursor,
                    includeAgents: includeAgents,
                    forceFullSync: forceFullSync,
                    generation: generation
                )
                await retryPendingOperations(generation: generation)
                let complete = !reconciliationRequested && localStore.loadPendingSyncEvents().isEmpty
                foregroundNeedsReconciliation = !complete
                if complete {
                    hasLoadedData = true
                    return true
                }
            } catch {
                if !renewed, Self.isUnauthorized(error), await renewAccessToken() {
                    renewed = true
                    reconciliationRequested = true
                    continue
                }
                handleRefreshError(error)
                return false
            }
        }
        return false
    }

    func refresh(includeAgents: Bool = true) async {
        guard token != nil else { return }
        if foregroundNeedsReconciliation {
            foregroundReconciliationIncludeAgents = foregroundReconciliationIncludeAgents || includeAgents
            if let foregroundReconciliationTask {
                await foregroundReconciliationTask.value
                if !foregroundNeedsReconciliation {
                    startEventStreamNow()
                }
                return
            }
            let generation = reconciliationGeneration
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.runForegroundReconciliation(generation: generation)
                guard self.reconciliationGeneration == generation else { return }
                self.foregroundReconciliationTask = nil
            }
            foregroundReconciliationTask = task
            await task.value
            if !foregroundNeedsReconciliation {
                startEventStreamNow()
            }
            return
        }
        if let reconciliationTask {
            reconciliationRequested = true
            reconciliationIncludeAgents = reconciliationIncludeAgents || includeAgents
            await reconciliationTask.value
            return
        }
        if isRefreshing {
            reconciliationRequested = true
            reconciliationIncludeAgents = reconciliationIncludeAgents || includeAgents
            return
        }
        let generation = reconciliationGeneration
        isRefreshing = true
        defer {
            isRefreshing = false
            hasLoadedData = true
            if reconciliationRequested && reconciliationTask == nil {
                let nextIncludeAgents = reconciliationIncludeAgents
                reconciliationIncludeAgents = false
                scheduleReconciliation(includeAgents: nextIncludeAgents)
            }
        }
        do {
            try await loadRemoteState(includeAgents: includeAgents, generation: generation)
            await retryPendingOperations(generation: generation)
        } catch {
            if Self.isUnauthorized(error), await renewAccessToken() {
                do {
                    try await loadRemoteState(includeAgents: includeAgents, generation: generation)
                    await retryPendingOperations(generation: generation)
                    return
                } catch {
                    handleRefreshError(error)
                    return
                }
            }
            // App lifecycle transitions can cancel an in-flight refresh. That
            // is not a user-facing network failure and should not paint a red
            // error banner over an otherwise healthy session list.
            handleRefreshError(error)
        }
    }

    private func loadRemoteState(includeAgents: Bool, generation: Int? = nil) async throws {
        async let s = client.listSessionsPage(limit: Self.initialSessionPageSize)
        async let p = client.listPushes()
        let commandTask: Task<ActiveCommandApplication?, Error>? =
            activeCommandCoordinator.commandIDForReconciliation == nil
            ? nil
            : Task { @MainActor [activeCommandCoordinator, client] in
                try await activeCommandCoordinator.reconcileCurrent(
                    get: { commandID in
                        try await client.getCommand(commandID: commandID)
                    },
                    replay: { canonicalEnvelope in
                        try await client.createCommand(canonicalEnvelope)
                    },
                    definitelyRejected: { error in
                        Self.commandSubmissionDefinitelyRejected(error)
                    }
                )
            }
        let agentsTask: Task<[Agent], Error>? = includeAgents
            ? Task { try await client.listAgents() }
            : nil
        let remoteSessionPage = try await s
        let remoteSessions = remoteSessionPage.sessions
        let newPushes = try await p
        let remoteAgents: [Agent]?
        if let agentsTask {
            remoteAgents = try await agentsTask.value
        } else {
            remoteAgents = nil
        }
        var commandApplication: ActiveCommandApplication?
        if let commandTask {
            commandApplication = try await commandTask.value
        }
        if let generation,
           (generation != reconciliationGeneration || token == nil || Task.isCancelled)
        {
            throw CancellationError()
        }
        let candidateCursor = remoteSessionPage.next_cursor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        nextSessionCursor = candidateCursor
        hasMoreSessions = remoteSessionPage.has_more
            && candidateCursor?.isEmpty == false
        let details = Dictionary(uniqueKeysWithValues: sessions.map { ($0.session_id, $0) })
        let mergedSessions = remoteSessions.map { summary -> Session in
            var merged = summary
            if let detail = details[summary.session_id] {
                merged.mergeDetail(from: detail)
            }
            return merged
        }
        let remoteIDs = Set(remoteSessions.map(\.session_id))
        let cachedOlderSessions = sessions.filter { !remoteIDs.contains($0.session_id) }
        self.sessions = (mergedSessions + cachedOlderSessions).sorted { lhs, rhs in
            if lhs.needsUser != rhs.needsUser { return lhs.needsUser && !rhs.needsUser }
            return lhs.updated_at > rhs.updated_at
        }
        if let remoteAgents {
            self.agents = remoteAgents.sorted { $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending }
            if let selectedAgentId, !self.agents.contains(where: { $0.agent_id == selectedAgentId }) {
                self.selectedAgentId = nil
                UserDefaults.standard.removeObject(forKey: "vab.selectedAgentId")
            }
        }
        noteNewKnocks(newPushes)
        if headphonesSimulated, let newest = newPushes.first, newest.push_id != pushes.first?.push_id {
            lastSpoken = newest.voice_script ?? newest.body
        }
        pushes = newPushes
        if let commandApplication {
            consumeCommandApplication(commandApplication)
        } else if commandTask != nil {
            // A definitive replay rejection clears the coordinator's generic
            // submitting presentation. Reflect that release in the UI so a
            // later local command is not visually stuck behind the old fence.
            publishActiveCommandState()
        }
        localStore.cacheSessions(self.sessions)
        localStore.cachePushes(newPushes)
        try await refreshMemorySnapshot(generation: generation)
        lastRefreshAt = Date()
        connectionState = .connected
        errorMessage = nil
    }

    private func clearInMemoryDetailCaches() {
        historyBySession = [:]
        messagesBySession = [:]
        retrievalsBySession = [:]
    }

    private func removeLocalSession(_ sessionID: String) {
        sessions.removeAll { $0.session_id == sessionID }
        historyBySession[sessionID] = nil
        messagesBySession[sessionID] = nil
        retrievalsBySession[sessionID] = nil
        localStore.removeSession(sessionID)
        if openSessionId == sessionID { openSessionId = nil }
    }

    private func removeLocalMessage(_ messageID: String, sessionID: String?) {
        if let sessionID {
            messagesBySession[sessionID]?.removeAll { $0.message_id == messageID }
        } else {
            for sessionID in messagesBySession.keys {
                messagesBySession[sessionID]?.removeAll { $0.message_id == messageID }
            }
        }
        localStore.removeMessage(messageID)
    }

    private func removeLocalRetrieval(_ retrievalID: String, sessionID: String?) {
        if let sessionID {
            retrievalsBySession[sessionID]?.removeAll { $0.retrieval_id == retrievalID }
        } else {
            for sessionID in retrievalsBySession.keys {
                retrievalsBySession[sessionID]?.removeAll { $0.retrieval_id == retrievalID }
            }
        }
        localStore.removeRetrieval(retrievalID)
    }

    /// Durable phone-change tombstones remove only the active user's row.
    /// Kept internal so synchronization isolation can be unit tested without
    /// exposing a Memory product action.
    @discardableResult
    func removeLocalMemory(_ memoryID: String) -> Bool {
        guard let scope = memoryCacheScope else { return false }
        let previous = memories
        memories.removeAll { $0.memory_id == memoryID }
        guard localStore.removeMemory(memoryID, in: scope) else {
            memories = previous
            return false
        }
        return true
    }

    private func handleRefreshError(_ error: Error) {
        let isCancellation = (error as? APIClientError).map { Self.isCancellation($0) } ?? false
        if Task.isCancelled || isCancellation { return }
        if Self.isUnauthorized(error) {
            logout()
            errorMessage = "Your sign-in expired. Please sign in again."
        } else {
            connectionState = .unavailable
            errorMessage = error.localizedDescription
        }
    }

    private func renewAccessToken() async -> Bool {
        guard let refreshToken else { return false }
        do {
            let auth = try await client.refreshAuth(refreshToken: refreshToken)
            try applyAuth(auth)
            return true
        } catch {
            return false
        }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        if case APIClientError.badStatus(401, _, _) = error { return true }
        return false
    }

    private static func isCancellation(_ error: APIClientError) -> Bool {
        if case let .network(message) = error {
            return message == "cancelled"
        }
        return false
    }

    /// Show an in-app popup for knocks that arrive after launch (and for very fresh ones on first poll).
    private func noteNewKnocks(_ newPushes: [DevPush]) {
        let ids = Set(newPushes.map(\.push_id))
        if !hasSeededPushIds {
            knownPushIds = ids
            hasSeededPushIds = true
            // After reinstall / cold start, still surface a knock from the last 3 minutes.
            if let newest = newestLiveKnock(in: newPushes), isFreshKnock(newest) {
                presentKnock(newest)
            }
            return
        }
        guard let newest = newestLiveKnock(in: newPushes), !knownPushIds.contains(newest.push_id) else {
            knownPushIds = ids
            return
        }
        knownPushIds = ids
        presentKnock(newest)
    }

    /// Dev/APNs inboxes retain delivery history. Only surface a push when its
    /// exact session is still waiting for a decision; otherwise a completed
    /// action from another client could interrupt the user with a dead popup.
    private func newestLiveKnock(in pushes: [DevPush]) -> DevPush? {
        pushes.first { push in
            sessions.first(where: { $0.session_id == push.session_id })?.needsUser == true
        }
    }

    private func presentKnock(_ push: DevPush) {
        // Home/settings UI tests create a needs_user fixture only to populate
        // the workspace. They opt out of the full-screen overlay explicitly;
        // the destructive confirmation test keeps the real overlay enabled.
        #if DEBUG
        if ProcessInfo.processInfo.environment["KNOCK_UI_TEST_SUPPRESS_KNOCK_OVERLAY"] == "1" {
            return
        }
        #endif
        knockAlert = KnockAlert(
            id: push.push_id,
            sessionId: push.session_id,
            title: push.title,
            body: push.body
        )
        #if targetEnvironment(simulator)
        #if DEBUG
        if ProcessInfo.processInfo.environment["KNOCK_UI_TEST_SUPPRESS_LOCAL_BANNER"] != "1" {
            scheduleLocalBanner(title: push.title, body: push.body, sessionId: push.session_id)
        }
        #else
        scheduleLocalBanner(title: push.title, body: push.body, sessionId: push.session_id)
        #endif
        #endif
    }

    private func isFreshKnock(_ push: DevPush) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let created = formatter.date(from: push.created_at)
            ?? ISO8601DateFormatter().date(from: push.created_at)
        guard let created else { return false }
        return Date().timeIntervalSince(created) < 180
    }

    private func scheduleLocalBanner(title: String, body: String, sessionId: String) {
        let content = UNMutableNotificationContent()
        content.title = "Knock Knock"
        content.subtitle = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "KNOCK_DECISION"
        content.userInfo = ["session_id": sessionId]
        let req = UNNotificationRequest(
            identifier: "knock-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                print("[push] local notify failed: \(error.localizedDescription)")
            }
        }
    }

    func reply(session: Session, actionKey: String) async -> PhoneReplyResponse? {
        guard actionInFlight == nil else { return nil }
        errorMessage = nil
        actionInFlight = actionKey
        defer { actionInFlight = nil }
        let enqueued = enqueue(.init(
            idempotencyKey: UUID().uuidString.lowercased(),
            kind: .reply,
            session_id: session.session_id,
            action_key: actionKey,
            action_id: nil,
            confirm: nil,
            created_at: Date()
        ))
        guard enqueued.inserted else {
            errorMessage = "This choice is already saved and will retry automatically."
            return nil
        }
        var operation = enqueued.operation
        operation.status = .inFlight
        operation.lastError = nil
        operation.failureCode = nil
        upsertPendingOperation(operation)
        do {
            let res = try await client.reply(
                sessionId: session.session_id,
                actionKey: actionKey,
                utterance: actionKey,
                idempotencyKey: operation.idempotency_key
            )
            removePendingOperation(operation.id)
            // The response is already authoritative backend state. Publish it
            // immediately so a destructive action can present its second
            // confirmation without waiting for a potentially paginated inbox
            // reconciliation on a slow mobile route.
            upsertSession(res.session)
            localStore.cacheSessions(sessions)
            connectionState = .connected
            errorMessage = nil
            Task { @MainActor [weak self] in
                await self?.refresh(includeAgents: false)
            }
            return res
        } catch let error as APIClientError {
            if Self.isRetryableNetwork(error) {
                operation.status = .pending
                operation.lastError = nil
                operation.failureCode = nil
                upsertPendingOperation(operation)
                errorMessage = "Offline. Your choice is saved and will retry automatically."
            } else {
                upsertPendingOperation(Self.pendingOperationAfterPermanentFailure(
                    operation,
                    error: error
                ))
                errorMessage = error.localizedDescription
            }
            return nil
        } catch {
            upsertPendingOperation(Self.pendingOperationAfterPermanentFailure(
                operation,
                error: error
            ))
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func confirm(session: Session, actionId: String, confirm: Bool) async {
        guard actionInFlight == nil else { return }
        errorMessage = nil
        actionInFlight = actionId
        defer { actionInFlight = nil }
        let enqueued = enqueue(.init(
            idempotencyKey: UUID().uuidString.lowercased(),
            kind: .confirm,
            session_id: session.session_id,
            action_key: nil,
            action_id: actionId,
            confirm: confirm,
            created_at: Date()
        ))
        guard enqueued.inserted else {
            errorMessage = "This decision is already saved and will retry automatically."
            return
        }
        var operation = enqueued.operation
        operation.status = .inFlight
        operation.lastError = nil
        operation.failureCode = nil
        upsertPendingOperation(operation)
        do {
            let res = try await client.confirm(
                sessionId: session.session_id,
                actionId: actionId,
                confirm: confirm,
                idempotencyKey: operation.idempotency_key
            )
            removePendingOperation(operation.id)
            upsertSession(res.session)
            localStore.cacheSessions(sessions)
            connectionState = .connected
            errorMessage = nil
            Task { @MainActor [weak self] in
                await self?.refresh(includeAgents: false)
            }
        } catch let error as APIClientError {
            if Self.isRetryableNetwork(error) {
                operation.status = .pending
                operation.lastError = nil
                operation.failureCode = nil
                upsertPendingOperation(operation)
                errorMessage = "Offline. Your decision is saved and will retry automatically."
            } else {
                upsertPendingOperation(Self.pendingOperationAfterPermanentFailure(
                    operation,
                    error: error
                ))
                errorMessage = error.localizedDescription
            }
        } catch {
            upsertPendingOperation(Self.pendingOperationAfterPermanentFailure(
                operation,
                error: error
            ))
            errorMessage = error.localizedDescription
        }
    }

    nonisolated static func coalescesPendingIntent(
        _ existing: PendingOperation,
        _ requested: PendingOperation
    ) -> Bool {
        existing.isPending &&
            existing.kind == requested.kind &&
            existing.session_id == requested.session_id &&
            existing.action_key == requested.action_key &&
            existing.action_id == requested.action_id &&
            existing.confirm == requested.confirm
    }

    private func enqueue(_ operation: PendingOperation) -> (operation: PendingOperation, inserted: Bool) {
        if let existing = pendingOperations.first(where: { Self.coalescesPendingIntent($0, operation) }) {
            return (existing, false)
        }
        upsertPendingOperation(operation)
        return (operation, true)
    }

    private func upsertPendingOperation(_ operation: PendingOperation) {
        if let index = pendingOperations.firstIndex(where: { $0.id == operation.id }) {
            pendingOperations[index] = operation
        } else {
            pendingOperations.append(operation)
        }
        pendingOperations.sort { $0.created_at < $1.created_at }
        _ = localStore.savePendingOperations(pendingOperations)
    }

    private func removePendingOperation(_ operationID: String) {
        pendingOperations.removeAll { $0.id == operationID }
        _ = localStore.savePendingOperations(pendingOperations)
    }

    private func retryPendingOperations(generation: Int? = nil) async {
        guard !pendingOperations.isEmpty else { return }
        guard pendingRetryCoordinator.beginOrRequestRerun() else { return }
        defer { pendingRetryCoordinator.finish() }
        var completedAny = false
        repeat {
            let operations = pendingOperations
            for operation in operations {
                if operation.status == .failed {
                    continue
                }
                var next = operation
                next.status = .inFlight
                next.lastError = nil
                next.failureCode = nil
                upsertPendingOperation(next)
                do {
                    switch operation.kind {
                    case .reply:
                        guard let actionKey = operation.action_key else {
                            next.status = .failed
                            next.lastError = "The saved reply has no action key."
                            next.failureCode = "missing_action_key"
                            upsertPendingOperation(next)
                            continue
                        }
                        _ = try await client.reply(
                            sessionId: operation.session_id,
                            actionKey: actionKey,
                            utterance: actionKey,
                            idempotencyKey: operation.idempotency_key
                        )
                    case .confirm:
                        guard let actionId = operation.action_id, let confirm = operation.confirm else {
                            next.status = .failed
                            next.lastError = "The saved confirmation is incomplete."
                            next.failureCode = "missing_confirmation_fields"
                            upsertPendingOperation(next)
                            continue
                        }
                        _ = try await client.confirm(
                            sessionId: operation.session_id,
                            actionId: actionId,
                            confirm: confirm,
                            idempotencyKey: operation.idempotency_key
                        )
                    }
                    guard Self.retryContextIsActive(generation: generation, currentGeneration: reconciliationGeneration, tokenAvailable: token != nil) else {
                        return
                    }
                    removePendingOperation(operation.id)
                    completedAny = true
                } catch let error as APIClientError {
                    guard Self.retryContextIsActive(generation: generation, currentGeneration: reconciliationGeneration, tokenAvailable: token != nil) else {
                        return
                    }
                    if Self.shouldRetryPendingOperation(error) {
                        if case let .badStatus(_, _, metadata) = error,
                           let requestID = metadata.requestID
                        {
                            print("[pending] retryable request=\(requestID) retry_after=\(metadata.retryAfter ?? 0)")
                        }
                        next.status = .pending
                        next.lastError = nil
                        next.failureCode = nil
                        upsertPendingOperation(next)
                    } else {
                        upsertPendingOperation(Self.pendingOperationAfterPermanentFailure(
                            operation,
                            error: error
                        ))
                    }
                } catch {
                    // Permanent failures stay visible so the user can retry after
                    // fixing the cause or explicitly discard the saved intent.
                    guard Self.retryContextIsActive(generation: generation, currentGeneration: reconciliationGeneration, tokenAvailable: token != nil) else {
                        return
                    }
                    upsertPendingOperation(Self.pendingOperationAfterPermanentFailure(
                        operation,
                        error: error
                    ))
                }
            }
        } while pendingRetryCoordinator.consumeRerun() && token != nil
        if completedAny {
            try? await loadRemoteState(includeAgents: false, generation: generation)
        }
    }

    func retryPendingOperation(_ operation: PendingOperation) async {
        guard let index = pendingOperations.firstIndex(where: { $0.id == operation.id }) else { return }
        pendingOperations[index].status = .pending
        pendingOperations[index].lastError = nil
        pendingOperations[index].failureCode = nil
        _ = localStore.savePendingOperations(pendingOperations)
        await retryPendingOperations()
    }

    func discardPendingOperation(_ operation: PendingOperation) {
        removePendingOperation(operation.id)
    }

    nonisolated private static func isRetryableNetwork(_ error: APIClientError) -> Bool {
        if case .network = error { return true }
        if case .decoding = error { return true }
        if case let .badStatus(code, _, metadata) = error {
            return metadata.retryable || code == 408 || code == 425 || code == 429 || code >= 500
        }
        return false
    }

    nonisolated private static func retryContextIsActive(
        generation: Int?,
        currentGeneration: Int,
        tokenAvailable: Bool
    ) -> Bool {
        guard tokenAvailable, !Task.isCancelled else { return false }
        guard let generation else { return true }
        return generation == currentGeneration
    }

    nonisolated static func shouldRetryPendingOperation(_ error: Error) -> Bool {
        guard let error = error as? APIClientError else { return false }
        return isRetryableNetwork(error)
    }

    nonisolated static func pendingOperationAfterPermanentFailure(
        _ operation: PendingOperation,
        error: Error
    ) -> PendingOperation {
        var failed = operation
        failed.status = .failed
        failed.lastError = error.localizedDescription
        failed.failureCode = (error as? APIClientError).map(pendingFailureCode)
            ?? "permanent_failure"
        return failed
    }

    nonisolated private static func pendingFailureCode(_ error: APIClientError) -> String {
        if case let .badStatus(code, _, _) = error { return "http_\(code)" }
        if case .network = error { return "network" }
        return "permanent_failure"
    }

}

private enum KeychainStore {
    private static let service = Bundle.main.bundleIdentifier ?? "hk.knockknock.app"

    static func read(account: String = "user-jwt") -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String = "user-jwt") {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete(account: String = "user-jwt") {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

import Foundation
import Combine
import Security
import UserNotifications

@MainActor
final class AppStore: ObservableObject {
    private static let settingsSchemaVersion = 3
    private static let settingsSchemaKey = "vab.settingsSchemaVersion"

    @Published var token: String? {
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
    @Published private(set) var pendingOperations: [PendingOperation] = []
    @Published var pendingCommandConfirmation: PendingCommandConfirmation? = nil
    @Published private(set) var latestCommandResponse: CommandResponse? = nil
    @Published private(set) var undoableCommandID: String? = nil
    @Published private(set) var voiceModelStatus = "Not prepared"
    @Published private(set) var voiceController: LocalVoiceCommandController?
    /// A knock can ask the main tab to open one exact agent session.
    @Published var openSessionId: String?

    let client = APIClient()
    private let localStore = SQLiteStore.shared
    private lazy var eventTransport = client.makeSessionEventTransport()
    private var refreshToken: String?
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
    private var pendingRetryInProgress = false
    private var eventStreamGeneration = 0
    private var appliedCursor: String?
    private var knownPushIds = Set<String>()
    private var hasSeededPushIds = false
    private weak var appDelegate: AppDelegate?
    private var pendingSessionToOpen: String?
    private var voiceModelManager: LocalVoiceModelManager?

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

    init() {
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
            localStore.clearUserData()
        }
        #endif
        let storedToken = KeychainStore.read() ?? UserDefaults.standard.string(forKey: "vab.token")
        let storedRefreshToken = KeychainStore.read(account: "refresh-token")
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
        apiBase = DemoConfig.runtimeApiBaseOverride()
            ?? UserDefaults.standard.string(forKey: "vab.apiBase")
            ?? DemoConfig.defaultApiBase
        if !email.isEmpty && UserDefaults.standard.string(forKey: "vab.email") == nil {
            UserDefaults.standard.set(email, forKey: "vab.email")
        }
        if !apiBase.isEmpty && UserDefaults.standard.string(forKey: "vab.apiBase") == nil {
            UserDefaults.standard.set(apiBase, forKey: "vab.apiBase")
        }
        localStore.migrateLegacyState()
        appliedCursor = localStore.loadAppliedCursor()
        sessions = localStore.loadSessions()
        pushes = localStore.loadPushes()
        pendingOperations = localStore.loadPendingOperations()
        pendingCommandConfirmation = localStore.loadPendingCommandConfirmation()
        if let url = URL(string: apiBase), url.host != nil {
            client.baseURL = url
        }
    }

    func bindPush(_ appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        appDelegate.onDeviceToken = { [weak self] token in
            Task { @MainActor in
                guard let self else { return }
                self.apnsToken = token
                UserDefaults.standard.set(token, forKey: "vab.apnsToken")
                if self.token != nil {
                    try? await self.client.registerDevice(pushToken: token)
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

    @discardableResult
    func applyApiBase() -> Bool {
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
        apiBase = trimmed
        UserDefaults.standard.set(trimmed, forKey: "vab.apiBase")
        stopEventStream()
        stopReconciliation()
        resetEventCursor()
        client.baseURL = url
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
        do {
            return try await client.search(query: query)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
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
        applyAuth(auth)
        // Device registration enables system delivery, but it must not
        // block the in-app decision surface. Simulators can lack a real
        // APNs entitlement, and a temporary registration outage should
        // still let the user sign in and poll the exact session inbox.
        do {
            try await client.registerDevice(pushToken: apnsToken)
        } catch {
            print("[push] device registration deferred: \(error.localizedDescription)")
        }
        resetEventCursor()
        startEventStream()
        await refresh()
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

    private func applyAuth(_ auth: AuthResponse) {
        token = auth.token
        if let nextRefresh = auth.refresh_token {
            refreshToken = nextRefresh
            client.refreshToken = nextRefresh
            KeychainStore.save(nextRefresh, account: "refresh-token")
        }
        UserDefaults.standard.set(email, forKey: "vab.email")
    }

    /// Downloads and verifies the configured Gemma artifact on demand. The
    /// model is never activated until the app's pinned public key verifies its
    /// manifest and bytes; if the release has not configured a model, the UI
    /// reports that explicitly and the voice button remains unavailable.
    func prepareLocalVoiceModel() async {
        guard token != nil else {
            voiceModelStatus = "Sign in before preparing voice"
            return
        }
        voiceModelStatus = "Preparing on-device voice model…"
        do {
            let manager: LocalVoiceModelManager
            if let existing = voiceModelManager {
                manager = existing
            } else {
                manager = try LocalVoiceModelManager()
            }
            voiceModelManager = manager
            if manager.activeModel == nil {
                let descriptor = try await client.getModelArtifactDescriptor(
                    modelID: LocalVoiceModelManager.defaultModelID
                )
                _ = try await manager.install(descriptor)
            }
            let generator = try manager.makeCommandGenerator()
            voiceController = LocalVoiceCommandController(generator: generator) { [weak self] envelope in
                guard let self else {
                    throw APIClientError.network("Knock Knock is no longer available")
                }
                return try await self.submitLocalCommand(envelope)
            }
            if let model = manager.activeModel {
                voiceModelStatus = "Ready · Gemma \(model.manifest.modelVersion)"
            } else {
                voiceModelStatus = "Model not installed"
            }
        } catch {
            voiceController = nil
            voiceModelStatus = "Unavailable · \(error.localizedDescription)"
            errorMessage = "On-device voice is not ready: \(error.localizedDescription)"
        }
    }

    private func submitLocalCommand(_ envelope: CommandEnvelope) async throws -> CommandResponse {
        let created = try await client.createCommand(envelope)
        handleCommandResponse(created)

        // Read back the server-owned state before presenting it. The create
        // response is useful for degraded connectivity, but GET is the
        // canonical source for risk, confirmation, and lifecycle state.
        guard let canonical = try? await client.getCommand(commandID: created.command_id) else {
            return created
        }
        handleCommandResponse(canonical)
        return canonical
    }

    private func handleCommandResponse(_ response: CommandResponse) {
        latestCommandResponse = response
        undoableCommandID = response.state == "succeeded" && response.action?.reversible == true
            ? response.command_id
            : nil
        guard response.state == "awaiting_confirmation" else { return }
        guard let action = response.action,
              action.confirm_required
        else {
            // Never infer a confirmation title or risk from the local intent.
            // An awaiting state without backend metadata is fail-closed.
            errorMessage = "This command needs server confirmation metadata before it can run."
            return
        }
        let token = response.confirmation_token
            ?? pendingCommandConfirmation
                .flatMap { $0.command_id == response.command_id ? $0.confirmation_token : nil }
        guard let token else {
            // GET intentionally does not repeat a one-time token. If the
            // create response was lost before persistence, fail closed and
            // require a new command instead of inventing or reusing a token.
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
            handleCommandResponse(canonical)
            if canonical.state != "awaiting_confirmation" {
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
            latestCommandResponse = canonical
            pendingCommandConfirmation = nil
            localStore.clearPendingCommandConfirmation()
            await refresh()
        } catch {
            errorMessage = "The command was not cancelled. (\(error.localizedDescription))"
        }
    }

    func undoCommand(commandID: String) async {
        errorMessage = nil
        do {
            let response = try await client.undoCommand(commandID: commandID)
            latestCommandResponse = (try? await client.getCommand(commandID: commandID)) ?? response
            undoableCommandID = nil
            await refresh()
        } catch {
            errorMessage = "Undo was not completed. (\(error.localizedDescription))"
        }
    }

    func logout() {
        if let refreshToken {
            let client = self.client
            Task { try? await client.logout(refreshToken: refreshToken) }
        }
        stopEventStream()
        stopReconciliation()
        token = nil
        refreshToken = nil
        client.refreshToken = nil
        KeychainStore.delete(account: "refresh-token")
        sessions = []
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
        pendingOperations = []
        pendingCommandConfirmation = nil
        latestCommandResponse = nil
        undoableCommandID = nil
        voiceController = nil
        voiceModelStatus = "Not prepared"
        localStore.clearUserData()
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
        pendingFullSync = false
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
            return ReconciliationResult(cursor: fallbackCursor ?? cursor, resetCursor: false)
        }

        var nextCursor = cursor
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
                        resetCursor: false
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
            return ReconciliationResult(cursor: fallbackCursor ?? nextCursor, resetCursor: false)
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
            return ReconciliationResult(cursor: nil, resetCursor: true)
        }
        try await loadRemoteState(includeAgents: includeAgents, generation: generation)
        guard reconciliationGeneration == generation, token != nil else {
            throw CancellationError()
        }
        return ReconciliationResult(cursor: nextCursor ?? fallbackCursor, resetCursor: false)
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
        async let s = client.listSessions()
        async let p = client.listPushes()
        let agentsTask: Task<[Agent], Error>? = includeAgents
            ? Task { try await client.listAgents() }
            : nil
        let remoteSessions = try await s
        let newPushes = try await p
        let remoteAgents: [Agent]?
        if let agentsTask {
            remoteAgents = try await agentsTask.value
        } else {
            remoteAgents = nil
        }
        if let generation,
           (generation != reconciliationGeneration || token == nil || Task.isCancelled)
        {
            return
        }
        let details = Dictionary(uniqueKeysWithValues: sessions.map { ($0.session_id, $0) })
        let mergedSessions = remoteSessions.map { summary -> Session in
            var merged = summary
            if let detail = details[summary.session_id] {
                merged.mergeDetail(from: detail)
            }
            return merged
        }
        self.sessions = mergedSessions.sorted { lhs, rhs in
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
        localStore.cacheSessions(mergedSessions)
        localStore.cachePushes(newPushes)
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
            applyAuth(auth)
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
        knockAlert = KnockAlert(
            id: push.push_id,
            sessionId: push.session_id,
            title: push.title,
            body: push.body
        )
        #if targetEnvironment(simulator)
        scheduleLocalBanner(title: push.title, body: push.body, sessionId: push.session_id)
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
            await refresh()
            return res
        } catch let error as APIClientError {
            if Self.isRetryableNetwork(error) {
                operation.status = .pending
                operation.lastError = nil
                operation.failureCode = nil
                upsertPendingOperation(operation)
                errorMessage = "Offline. Your choice is saved and will retry automatically."
            } else {
                removePendingOperation(operation.id)
                errorMessage = error.localizedDescription
            }
            return nil
        } catch {
            removePendingOperation(operation.id)
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
            _ = try await client.confirm(
                sessionId: session.session_id,
                actionId: actionId,
                confirm: confirm,
                idempotencyKey: operation.idempotency_key
            )
            removePendingOperation(operation.id)
            await refresh()
        } catch let error as APIClientError {
            if Self.isRetryableNetwork(error) {
                operation.status = .pending
                operation.lastError = nil
                operation.failureCode = nil
                upsertPendingOperation(operation)
                errorMessage = "Offline. Your decision is saved and will retry automatically."
            } else {
                removePendingOperation(operation.id)
                errorMessage = error.localizedDescription
            }
        } catch {
            removePendingOperation(operation.id)
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
        guard !pendingOperations.isEmpty, !pendingRetryInProgress else { return }
        pendingRetryInProgress = true
        defer { pendingRetryInProgress = false }
        var completedAny = false
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
                            idempotencyKey: operation.id
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
                    next.status = .failed
                    next.lastError = error.localizedDescription
                    next.failureCode = Self.pendingFailureCode(error)
                    upsertPendingOperation(next)
                }
            } catch {
                // Permanent failures stay visible so the user can retry after
                // fixing the cause or explicitly discard the saved intent.
                guard Self.retryContextIsActive(generation: generation, currentGeneration: reconciliationGeneration, tokenAvailable: token != nil) else {
                    return
                }
                next.status = .failed
                next.lastError = error.localizedDescription
                next.failureCode = "permanent_failure"
                upsertPendingOperation(next)
            }
        }
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

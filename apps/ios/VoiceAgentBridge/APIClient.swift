import Foundation

struct APIErrorMetadata: Equatable, Sendable {
    let retryable: Bool
    let retryAfter: Int?
    let requestID: String?
    /// Canonical backend error code, when the response carried a structured
    /// error envelope. HTTP status alone is not specific enough to prove that
    /// a command was rejected before persistence.
    let errorCode: String?

    init(
        retryable: Bool,
        retryAfter: Int?,
        requestID: String?,
        errorCode: String? = nil
    ) {
        self.retryable = retryable
        self.retryAfter = retryAfter
        self.requestID = requestID
        self.errorCode = errorCode
    }
}

enum APIClientError: LocalizedError {
    case badStatus(Int, String, APIErrorMetadata)
    case decoding
    case noToken
    case missingPushToken
    case invalidPushToken
    case invalidBaseURL
    case network(String)

    var errorDescription: String? {
        switch self {
        case let .badStatus(code, message, metadata):
            if let requestID = metadata.requestID, !requestID.isEmpty {
                return "HTTP \(code): \(message) (request \(requestID))"
            }
            return "HTTP \(code): \(message)"
        case .decoding: return "The server returned an invalid response."
        case .noToken: return "Not signed in"
        case .missingPushToken: return "Waiting for a real APNs device token."
        case .invalidPushToken: return "The APNs device token is invalid."
        case .invalidBaseURL: return "Enter a valid server URL (use HTTPS for production)."
        case let .network(message): return "Network error: \(message)"
        }
    }
}

struct EmptyJSON: Decodable {}
struct EmptyBody: Encodable {}

final class APIClient: @unchecked Sendable {
    /// The endpoint is user- or bundle-configured. There is no fixed physical
    /// device address because a Mac's LAN address can change at any time.
    var baseURL: URL? {
        get {
            let configured = DemoConfig.runtimeApiBaseOverride()
                ?? UserDefaults.standard.string(forKey: "vab.apiBase")
                ?? DemoConfig.defaultApiBase
            let raw = configured
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #if DEBUG
            let requiresHTTPS = false
            #else
            let requiresHTTPS = true
            #endif
            guard DemoConfig.isValidApiBase(raw, requireHTTPS: requiresHTTPS),
                  let url = URL(string: raw)
            else {
                return nil
            }
            return url
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.absoluteString, forKey: "vab.apiBase")
            } else {
                UserDefaults.standard.removeObject(forKey: "vab.apiBase")
            }
        }
    }
    var token: String?
    var refreshToken: String?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func register(email: String, password: String) async throws -> AuthResponse {
        try await post("/v1/auth/register", body: ["email": email, "password": password], auth: false)
    }

    func login(email: String, password: String) async throws -> AuthResponse {
        try await post("/v1/auth/login", body: ["email": email, "password": password], auth: false)
    }

    func refreshAuth(refreshToken: String) async throws -> AuthResponse {
        try await post(
            "/v1/auth/refresh",
            body: ["refresh_token": refreshToken],
            auth: false
        )
    }

    func logout(refreshToken: String) async throws {
        let _: EmptyJSON = try await post(
            "/v1/auth/logout",
            body: ["refresh_token": refreshToken],
            auth: false
        )
    }

    func createPairingCode(ttlSeconds: Int = 600) async throws -> PairingCodeResponse {
        struct Body: Encodable {
            let ttl_sec: Int
        }
        return try await post(
            "/v1/pairing/code",
            body: Body(ttl_sec: ttlSeconds),
            auth: true
        )
    }

    func registerDevice(pushToken: String?) async throws {
        struct DeviceBody: Encodable {
            let platform: String
            let push_token: String
            let locale: String
            let timezone: String
            let device_id: String
        }
        #if targetEnvironment(simulator)
        let registration = try Self.deviceRegistration(pushToken: pushToken, isSimulator: true)
        #else
        let registration = try Self.deviceRegistration(pushToken: pushToken, isSimulator: false)
        #endif
        let _: EmptyJSON = try await post(
            "/v1/phone/devices",
            body: DeviceBody(
                platform: registration.platform,
                push_token: registration.token,
                locale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
                timezone: TimeZone.current.identifier,
                device_id: Self.stableDeviceID
            ),
            auth: true
        )
    }

    static func deviceRegistration(
        pushToken: String?,
        isSimulator: Bool
    ) throws -> (platform: String, token: String) {
        if isSimulator {
            return ("ios_simulator", pushToken ?? "sim-\(UUID().uuidString)")
        }
        guard let pushToken else { throw APIClientError.missingPushToken }
        let normalized = pushToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.utf8.count == 64,
              normalized.unicodeScalars.allSatisfy({
                  (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
              })
        else { throw APIClientError.invalidPushToken }
        return ("ios", normalized)
    }

    private static var stableDeviceID: String {
        let key = "vab.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = "ios-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    /// Stable per-installation identifier used for backend multi-device scope
    /// and command tracing. It is app-generated and never comes from a model.
    var currentDeviceID: String {
        Self.stableDeviceID
    }

    func listSessionsPage(
        before: String? = nil,
        limit: Int = 50
    ) async throws -> SessionsResponse {
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))]
        if let before, !before.isEmpty {
            query.append(URLQueryItem(name: "before", value: before))
        }
        return try await get("/v1/phone/sessions", query: query)
    }

    func listSessions() async throws -> [Session] {
        var sessions: [Session] = []
        var cursor: String?
        while true {
            let page = try await listSessionsPage(before: cursor)
            sessions.append(contentsOf: page.sessions)
            guard page.has_more,
                  let nextCursor = page.next_cursor,
                  !nextCursor.isEmpty,
                  nextCursor != cursor
            else {
                break
            }
            cursor = nextCursor
        }
        return sessions
    }

    /// Fetch durable phone changes after an applied cursor. The endpoint is
    /// optional during the compatibility window; AppStore falls back to the
    /// existing REST snapshot when an older backend returns 404.
    func sync(after cursor: String?, limit: Int = 50) async throws -> SyncResponse {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))
        ]
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "after", value: cursor))
        }
        return try await get("/v1/phone/sync", query: query)
    }

    func listAgents() async throws -> [Agent] {
        let res: AgentsResponse = try await get("/v1/agents")
        return res.agents
    }

    func listHistoryPage(
        sessionId: String,
        before: String? = nil,
        limit: Int = 50
    ) async throws -> HistoryResponse {
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))]
        if let before, !before.isEmpty {
            query.append(URLQueryItem(name: "before", value: before))
        }
        return try await get(
            "/v1/phone/sessions/\(sessionId)/history",
            query: query
        )
    }

    func listHistory(sessionId: String) async throws -> [HistoryEntry] {
        var entries: [HistoryEntry] = []
        var cursor: String?
        while true {
            let page = try await listHistoryPage(sessionId: sessionId, before: cursor)
            entries.append(contentsOf: page.entries)
            guard page.has_more,
                  let nextCursor = page.next_cursor,
                  !nextCursor.isEmpty,
                  nextCursor != cursor
            else {
                break
            }
            cursor = nextCursor
        }
        return entries
    }

    func getSessionDetail(sessionId: String) async throws -> SessionDetailResponse {
        try await get("/v1/phone/sessions/\(sessionId)")
    }

    func listMessages(
        sessionId: String,
        before: String? = nil,
        limit: Int = 50
    ) async throws -> MessagePage {
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))]
        if let before, !before.isEmpty {
            query.append(URLQueryItem(name: "before", value: before))
        }
        return try await get("/v1/phone/sessions/\(sessionId)/messages", query: query)
    }

    func search(query: String, limit: Int = 50) async throws -> SearchResponse {
        let items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50))),
        ]
        return try await get("/v1/phone/search", query: items)
    }

    func updateSession(
        sessionId: String,
        title: String?,
        archived: Bool?
    ) async throws -> SessionDetailResponse {
        struct Body: Encodable {
            let title: String?
            let archived: Bool?
        }
        return try await patch(
            "/v1/phone/sessions/\(sessionId)",
            body: Body(title: title, archived: archived),
            auth: true
        )
    }

    func deleteSession(sessionId: String) async throws -> DeletedSessionResponse {
        try await delete("/v1/phone/sessions/\(sessionId)")
    }

    func exportSession(sessionId: String) async throws -> SessionExportResponse {
        try await get("/v1/phone/sessions/\(sessionId)/export")
    }

    func listPushes() async throws -> [DevPush] {
        let res: DevPushesResponse = try await get("/v1/dev/pushes")
        return res.pushes
    }

    func markPushRead(pushId: String) async throws -> DevPush {
        try await post(
            "/v1/phone/pushes/\(pushId)/read",
            body: EmptyBody(),
            auth: true
        )
    }

    func markAllPushesRead() async throws -> PushReadAllResponse {
        try await post(
            "/v1/phone/pushes/read-all",
            body: EmptyBody(),
            auth: true
        )
    }

    /// Opens the foreground-only server-sent event stream. The stream carries
    /// small invalidation signals; AppStore then reconciles through REST so a
    /// reconnect cannot leave the inbox partially updated.
    func openEventStream(since: String?) async throws -> URLSession.AsyncBytes {
        let request = try makeEventStreamRequest(since: since)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            throw APIClientError.network(error.localizedDescription)
        } catch {
            throw APIClientError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.network("The event stream response was not HTTP.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw APIClientError.badStatus(
                http.statusCode,
                "Event stream request failed",
                APIErrorMetadata(
                    retryable: http.statusCode == 408 || http.statusCode == 425 || http.statusCode == 429 || http.statusCode >= 500,
                    retryAfter: Int(http.value(forHTTPHeaderField: "Retry-After") ?? ""),
                    requestID: http.value(forHTTPHeaderField: "X-Request-ID")
                )
            )
        }
        return bytes
    }

    /// Builds the resumable SSE request separately from the network call so
    /// the cursor/header contract can be covered without opening a socket.
    func makeEventStreamRequest(since: String?) throws -> URLRequest {
        var query: [URLQueryItem] = []
        if let since, !since.isEmpty {
            query.append(URLQueryItem(name: "since", value: since))
        }
        var request = URLRequest(url: try makeURL("/v1/phone/events", query: query))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 45
        for (field, value) in Self.eventStreamResumeHeaders(since: since) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        try applyAuth(&request)
        return request
    }

    static func eventStreamResumeHeaders(since: String?) -> [String: String] {
        var headers = ["Accept": "text/event-stream"]
        if let since, !since.isEmpty {
            headers["Last-Event-ID"] = since
        }
        return headers
    }

    /// Default Knock Knock realtime transport. The transport itself is
    /// generic so another feature can provide a different Decodable payload.
    func makeSessionEventTransport() -> ServerSentEventsTransport<SessionInvalidation> {
        ServerSentEventsTransport { [weak self] since in
            guard let self else {
                throw APIClientError.network("The API client is unavailable.")
            }
            return try await self.openEventStream(since: since)
        }
    }

    func reply(
        sessionId: String,
        actionKey: String,
        utterance: String?,
        idempotencyKey: String? = nil
    ) async throws -> PhoneReplyResponse {
        struct Body: Encodable {
            let action_key: String
            let utterance: String?
            let idempotency_key: String?
        }
        return try await post(
            "/v1/phone/sessions/\(sessionId)/reply",
            body: Body(
                action_key: actionKey,
                utterance: utterance,
                idempotency_key: idempotencyKey
            ),
            auth: true
        )
    }

    func confirm(
        sessionId: String,
        actionId: String,
        confirm: Bool,
        idempotencyKey: String? = nil
    ) async throws -> PhoneReplyResponse {
        struct Body: Encodable {
            let action_id: String
            let confirm: Bool
            let idempotency_key: String?
        }
        return try await post(
            "/v1/phone/sessions/\(sessionId)/confirm",
            body: Body(
                action_id: actionId,
                confirm: confirm,
                idempotency_key: idempotencyKey
            ),
            auth: true
        )
    }

    /// Submit a locally validated CommandEnvelope. The backend remains the
    /// authority: this method only transports the draft and returns its
    /// persisted lifecycle state.
    func createCommand(_ envelope: CommandEnvelope) async throws -> CommandResponse {
        try await post("/v1/phone/commands", body: envelope, auth: true)
    }

    func getCommand(commandID: String) async throws -> CommandResponse {
        try await get("/v1/phone/commands/\(commandID)")
    }

    func confirmCommand(commandID: String, confirmationToken: String) async throws -> CommandResponse {
        struct Body: Encodable {
            let confirmation_token: String
        }
        return try await post(
            "/v1/phone/commands/\(commandID)/confirm",
            body: Body(confirmation_token: confirmationToken),
            auth: true
        )
    }

    func cancelCommand(commandID: String) async throws -> CommandResponse {
        try await post(
            "/v1/phone/commands/\(commandID)/cancel",
            body: EmptyBody(),
            auth: true
        )
    }

    func undoCommand(commandID: String) async throws -> CommandResponse {
        try await post(
            "/v1/phone/commands/\(commandID)/undo",
            body: EmptyBody(),
            auth: true
        )
    }

    func getModelArtifactDescriptor(modelID: String) async throws -> ModelArtifactDescriptorResponse {
        try await get("/v1/phone/models/\(modelID)")
    }

    private func makeURL(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let baseURL,
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw APIClientError.invalidBaseURL
        }
        guard !query.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIClientError.invalidBaseURL
        }
        components.queryItems = query
        guard let result = components.url else {
            throw APIClientError.invalidBaseURL
        }
        return result
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var req = URLRequest(url: try makeURL(path, query: query))
        req.httpMethod = "GET"
        // Authenticated API state must come from the backend or from our
        // explicit SQLite offline cache. URLCache can otherwise replay a
        // successful response while the device is offline and make the UI
        // incorrectly report that it is connected.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        try applyAuth(&req)
        return try await send(req)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B, auth: Bool) async throws -> T {
        var req = URLRequest(url: try makeURL(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        if auth { try applyAuth(&req) }
        return try await send(req)
    }

    private func patch<T: Decodable, B: Encodable>(_ path: String, body: B, auth: Bool) async throws -> T {
        var req = URLRequest(url: try makeURL(path))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        if auth { try applyAuth(&req) }
        return try await send(req)
    }

    private func delete<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: try makeURL(path))
        req.httpMethod = "DELETE"
        try applyAuth(&req)
        return try await send(req)
    }

    private func applyAuth(_ req: inout URLRequest) throws {
        guard let token else { throw APIClientError.noToken }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.stableDeviceID, forHTTPHeaderField: "X-Device-ID")
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        var request = req
        request.timeoutInterval = 15
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: request)
        } catch let error as URLError {
            let path = request.url?.path ?? "request"
            throw APIClientError.network("\(path): \(error.localizedDescription)")
        } catch {
            let path = request.url?.path ?? "request"
            throw APIClientError.network("\(path): \(error.localizedDescription)")
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIClientError.network("The server response was not HTTP.")
        }
        let code = http.statusCode
        guard (200 ..< 300).contains(code) else {
            let fallback = String(data: data, encoding: .utf8) ?? "Request failed"
            let decoded = try? JSONDecoder().decode(APIErrorBody.self, from: data)
            let message = decoded?.message ?? fallback
            let metadata = APIErrorMetadata(
                retryable: decoded?.retryable ?? (code == 408 || code == 425 || code == 429 || code >= 500),
                retryAfter: decoded?.retry_after ?? Int(http.value(forHTTPHeaderField: "Retry-After") ?? ""),
                requestID: decoded?.request_id ?? http.value(forHTTPHeaderField: "X-Request-ID"),
                errorCode: decoded?.error
            )
            throw APIClientError.badStatus(code, message, metadata)
        }
        if T.self == EmptyJSON.self {
            return EmptyJSON() as! T
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIClientError.decoding
        }
    }
}

struct RealtimeEvent<Payload: Decodable> {
    let id: String?
    let name: String
    let payload: Payload
}

/// Generic SSE transport used by the app's default realtime implementation.
/// It owns framing, JSON decoding, cancellation, and stream termination; the
/// caller only handles typed events.
final class ServerSentEventsTransport<Payload: Decodable>: @unchecked Sendable {
    typealias StreamOpener = @Sendable (String?) async throws -> URLSession.AsyncBytes

    private let open: StreamOpener

    init(open: @escaping StreamOpener) {
        self.open = open
    }

    func stream(since: String?) async throws -> AsyncThrowingStream<RealtimeEvent<Payload>, Error> {
        let bytes = try await open(since)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = ServerSentEventParser()
                let decoder = JSONDecoder()
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        if let raw = parser.consume(line) {
                            guard let data = raw.data.data(using: .utf8),
                                  let payload = try? decoder.decode(Payload.self, from: data)
                            else {
                                continuation.finish(throwing: APIClientError.decoding)
                                return
                            }
                            continuation.yield(
                                RealtimeEvent(id: raw.id, name: raw.name, payload: payload)
                            )
                        }
                    }
                    if let raw = parser.finish(),
                       let data = raw.data.data(using: .utf8),
                       let payload = try? decoder.decode(Payload.self, from: data) {
                        continuation.yield(
                            RealtimeEvent(id: raw.id, name: raw.name, payload: payload)
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

struct RawServerSentEvent {
    let id: String?
    let name: String
    let data: String
}

struct ServerSentEventParser {
    private var id: String?
    private var name = "message"
    private var dataLines: [String] = []

    mutating func consume(_ rawLine: String) -> RawServerSentEvent? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            return finish()
        }
        guard !line.hasPrefix(":") else { return nil }

        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.first == " " {
            value.removeFirst()
        }
        switch field {
        case "id": id = value
        case "event": name = value.isEmpty ? "message" : value
        case "data": dataLines.append(value)
        default: break
        }
        return nil
    }

    mutating func finish() -> RawServerSentEvent? {
        guard !dataLines.isEmpty else {
            reset()
            return nil
        }
        let event = RawServerSentEvent(
            id: id,
            name: name,
            data: dataLines.joined(separator: "\n")
        )
        reset()
        return event
    }

    private mutating func reset() {
        id = nil
        name = "message"
        dataLines = []
    }
}

import Foundation

enum APIClientError: LocalizedError {
    case badStatus(Int, String)
    case decoding
    case noToken
    case invalidBaseURL
    case network(String)

    var errorDescription: String? {
        switch self {
        case let .badStatus(code, message): return "HTTP \(code): \(message)"
        case .decoding: return "The server returned an invalid response."
        case .noToken: return "Not signed in"
        case .invalidBaseURL: return "Enter a valid server URL (use HTTPS for production)."
        case let .network(message): return "Network error: \(message)"
        }
    }
}

struct EmptyJSON: Decodable {}

final class APIClient: @unchecked Sendable {
    /// The endpoint is user- or bundle-configured. There is no fixed physical
    /// device address because a Mac's LAN address can change at any time.
    var baseURL: URL? {
        get {
            let raw = (UserDefaults.standard.string(forKey: "vab.apiBase") ?? DemoConfig.defaultApiBase)
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
        let platform = "ios_simulator"
        let token = pushToken ?? "sim-\(UUID().uuidString)"
        #else
        let platform = "ios"
        let token = pushToken ?? "dev-\(UUID().uuidString)"
        #endif
        let _: EmptyJSON = try await post(
            "/v1/phone/devices",
            body: DeviceBody(
                platform: platform,
                push_token: token,
                locale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
                timezone: TimeZone.current.identifier,
                device_id: Self.stableDeviceID
            ),
            auth: true
        )
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

    func listSessions() async throws -> [Session] {
        let res: SessionsResponse = try await get("/v1/phone/sessions")
        return res.sessions
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

    func listHistory(sessionId: String) async throws -> [HistoryEntry] {
        let res: HistoryResponse = try await get(
            "/v1/phone/sessions/\(sessionId)/history"
        )
        return res.entries
    }

    func listPushes() async throws -> [DevPush] {
        let res: DevPushesResponse = try await get("/v1/dev/pushes")
        return res.pushes
    }

    /// Opens the foreground-only server-sent event stream. The stream carries
    /// small invalidation signals; AppStore then reconciles through REST so a
    /// reconnect cannot leave the inbox partially updated.
    func openEventStream(since: String?) async throws -> URLSession.AsyncBytes {
        var query: [URLQueryItem] = []
        if let since, !since.isEmpty {
            query.append(URLQueryItem(name: "since", value: since))
        }
        var request = URLRequest(url: try makeURL("/v1/phone/events", query: query))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 45
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let since, !since.isEmpty {
            request.setValue(since, forHTTPHeaderField: "Last-Event-ID")
        }
        try applyAuth(&request)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let error as URLError {
            throw APIClientError.network(error.localizedDescription)
        } catch {
            throw APIClientError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.network("The event stream response was not HTTP.")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw APIClientError.badStatus(http.statusCode, "Event stream request failed")
        }
        return bytes
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

    func reply(sessionId: String, actionKey: String, utterance: String?) async throws -> PhoneReplyResponse {
        struct Body: Encodable {
            let action_key: String
            let utterance: String?
        }
        return try await post(
            "/v1/phone/sessions/\(sessionId)/reply",
            body: Body(action_key: actionKey, utterance: utterance),
            auth: true
        )
    }

    func confirm(sessionId: String, actionId: String, confirm: Bool) async throws -> PhoneReplyResponse {
        struct Body: Encodable {
            let action_id: String
            let confirm: Bool
        }
        return try await post(
            "/v1/phone/sessions/\(sessionId)/confirm",
            body: Body(action_id: actionId, confirm: confirm),
            auth: true
        )
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

    private func applyAuth(_ req: inout URLRequest) throws {
        guard let token else { throw APIClientError.noToken }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        var request = req
        request.timeoutInterval = 15
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw APIClientError.network(error.localizedDescription)
        } catch {
            throw APIClientError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIClientError.network("The server response was not HTTP.")
        }
        let code = http.statusCode
        guard (200 ..< 300).contains(code) else {
            let fallback = String(data: data, encoding: .utf8) ?? "Request failed"
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.message
                ?? fallback
            throw APIClientError.badStatus(code, message)
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

private struct RawServerSentEvent {
    let id: String?
    let name: String
    let data: String
}

private struct ServerSentEventParser {
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

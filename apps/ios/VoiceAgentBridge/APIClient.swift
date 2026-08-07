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
                locale: "zh-Hans"
            ),
            auth: true
        )
    }

    func listSessions() async throws -> [Session] {
        let res: SessionsResponse = try await get("/v1/phone/sessions")
        return res.sessions
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

    private func makeURL(_ path: String) throws -> URL {
        guard let baseURL,
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw APIClientError.invalidBaseURL
        }
        return url
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: try makeURL(path))
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

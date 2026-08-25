import Foundation
import Network
import Security

enum APITransportPolicy {
    /// iOS Happy Eyeballs can stick to a broken IPv6 path while IPv4 still
    /// reaches Cloudflare Workers. Retry those connect failures over IPv4+SNI.
    static func shouldRetryOverIPv4(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut:
            return true
        default:
            return false
        }
    }
}

enum IPv4HTTPSClient {
    static func data(for request: URLRequest, timeout: TimeInterval = 15) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty
        else {
            throw APIClientError.invalidBaseURL
        }
        let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) ?? .https
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let parameters = NWParameters(tls: tls, tcp: .init())
        if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let queue = DispatchQueue(label: "hk.knockknock.ipv4-https")
        try await ready(connection, queue: queue, timeout: timeout)
        let payload = try http1RequestData(from: request, host: host)
        try await send(payload, on: connection, timeout: timeout)
        let raw = try await receiveAll(on: connection, timeout: timeout)
        connection.cancel()
        return try parseHTTPResponse(raw, url: url)
    }

    private static func ready(
        _ connection: NWConnection,
        queue: DispatchQueue,
        timeout: TimeInterval
    ) async throws {
        try await withThrowingTimeout(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let lock = ResumeOnce()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        lock.resume { continuation.resume() }
                    case let .failed(error):
                        lock.resume { continuation.resume(throwing: error) }
                    case .cancelled:
                        lock.resume {
                            continuation.resume(throwing: URLError(.cancelled))
                        }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }

    private static func send(
        _ data: Data,
        on connection: NWConnection,
        timeout: TimeInterval
    ) async throws {
        try await withThrowingTimeout(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(
                    content: data,
                    completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                )
            }
        }
    }

    private static func receiveAll(
        on connection: NWConnection,
        timeout: TimeInterval
    ) async throws -> Data {
        try await withThrowingTimeout(timeout) {
            var collected = Data()
            while true {
                let (chunk, isComplete): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        continuation.resume(returning: (data, complete))
                    }
                }
                if let chunk, !chunk.isEmpty {
                    collected.append(chunk)
                }
                if isComplete || chunk == nil || chunk?.isEmpty == true {
                    break
                }
            }
            return collected
        }
    }

    private static func http1RequestData(from request: URLRequest, host: String) throws -> Data {
        let method = request.httpMethod ?? "GET"
        var path = request.url?.path ?? "/"
        if path.isEmpty { path = "/" }
        if let query = request.url?.query, !query.isEmpty {
            path += "?\(query)"
        }
        var headerLines = [
            "\(method) \(path) HTTP/1.1",
            "Host: \(host)",
            "Connection: close",
            "User-Agent: KnockKnock-iOS/0.1",
            "Accept: application/json",
        ]
        if let headers = request.allHTTPHeaderFields {
            for (key, value) in headers where key.lowercased() != "host" {
                headerLines.append("\(key): \(value)")
            }
        }
        if let body = request.httpBody {
            headerLines.append("Content-Length: \(body.count)")
        }
        var message = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var data = Data(message.utf8)
        if let body = request.httpBody {
            data.append(body)
        }
        return data
    }

    private static func parseHTTPResponse(_ raw: Data, url: URL) throws -> (Data, HTTPURLResponse) {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw APIClientError.network("IPv4 fallback: incomplete HTTP response")
        }
        let headerData = raw.subdata(in: raw.startIndex..<headerEnd.lowerBound)
        var body = raw.subdata(in: headerEnd.upperBound..<raw.endIndex)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw APIClientError.decoding
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else {
            throw APIClientError.network("IPv4 fallback: missing status")
        }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let code = Int(statusParts[1]) else {
            throw APIClientError.network("IPv4 fallback: bad status line")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let split = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<split])
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            headers[key] = String(value)
        }
        if headers["Transfer-Encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunkedBody(body)
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            throw APIClientError.network("IPv4 fallback: could not build response")
        }
        return (body, response)
    }

    private static func decodeChunkedBody(_ data: Data) throws -> Data {
        var remaining = data
        var body = Data()
        while !remaining.isEmpty {
            guard let lineEnd = remaining.range(of: Data("\r\n".utf8)) else { break }
            let sizeLine = remaining.subdata(in: remaining.startIndex..<lineEnd.lowerBound)
            remaining = remaining.subdata(in: lineEnd.upperBound..<remaining.endIndex)
            guard let sizeText = String(data: sizeLine, encoding: .utf8)?
                .split(separator: ";").first
                .map(String.init),
                let size = Int(sizeText, radix: 16)
            else {
                throw APIClientError.network("IPv4 fallback: bad chunk size")
            }
            if size == 0 { break }
            guard remaining.count >= size + 2 else {
                throw APIClientError.network("IPv4 fallback: truncated chunk")
            }
            body.append(remaining.prefix(size))
            remaining = remaining.dropFirst(size + 2)
        }
        return body
    }

    private static func withThrowingTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let resumeOnce = ResumeOnce()
            Task {
                do {
                    let value = try await work()
                    resumeOnce.resume { continuation.resume(returning: value) }
                } catch {
                    resumeOnce.resume { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                resumeOnce.resume {
                    continuation.resume(throwing: URLError(.timedOut))
                }
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private var resumed = false
    private let lock = NSLock()

    func resume(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }
}

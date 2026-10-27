import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPError: Error, Equatable, Sendable {
    /// HTTP 429, with the server's Retry-After in seconds if it sent one.
    case rateLimited(retryAfter: Double?)
    case unauthorized
    case notFound
    case server(status: Int)
    case client(status: Int, body: String)
    case transport(String)
    case decoding(String)

    /// Worth retrying with backoff.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .server, .transport: return true
        default: return false
        }
    }

    public var userMessage: String {
        switch self {
        case .rateLimited: return "Rate limit reached. Waiting before retrying."
        case .unauthorized: return "The API key was rejected. Check it in Settings."
        case .notFound: return "Not found."
        case .server(let s): return "The data provider had a server error (\(s))."
        case .client(let s, _): return "The request was rejected (\(s))."
        case .transport(let m): return "Network error: \(m)"
        case .decoding(let m): return "Unexpected response format: \(m)"
        }
    }
}

/// Minimal HTTP abstraction so providers can be tested with canned responses.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> Data
}

public struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 30)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw HTTPError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.transport("No HTTP response") }
        try Self.check(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"), body: data)
        return data
    }

    static func check(status: Int, retryAfter: String?, body: Data) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw HTTPError.unauthorized
        case 404: throw HTTPError.notFound
        case 429: throw HTTPError.rateLimited(retryAfter: retryAfter.flatMap(Double.init))
        case 500...: throw HTTPError.server(status: status)
        default: throw HTTPError.client(status: status, body: String(decoding: body.prefix(300), as: UTF8.self))
        }
    }
}

extension URL {
    /// Builds a URL from a base string and query items, failing loudly on programmer error.
    static func make(_ base: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents(string: base)!
        if !query.isEmpty {
            c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return c.url!
    }
}

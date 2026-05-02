import Foundation

struct APIClient: Sendable {
    static let shared = APIClient()

    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = AppConfig.apiBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = APIClient.flexibleDateFormatterWithMillis.date(from: raw) {
                return date
            }
            if let date = APIClient.flexibleDateFormatter.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot parse date: \(raw)"
            )
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(f.string(from: date))
        }
        return e
    }()

    private static let flexibleDateFormatterWithMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let flexibleDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func makeURL(path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty {
            components.queryItems = query
        }
        return components.url!
    }

    private func send<T: Decodable>(_ request: URLRequest, decoding: T.Type) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? Self.decoder.decode(APIErrorPayload.self, from: data))?.error
                throw APIError.http(status: http.statusCode, message: message)
            }
            if T.self == EmptyResponse.self {
                return EmptyResponse() as! T
            }
            do {
                return try Self.decoder.decode(T.self, from: data)
            } catch {
                throw APIError.decoding(error)
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error)
        }
    }

    private func sendVoid(_ request: URLRequest) async throws {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? Self.decoder.decode(APIErrorPayload.self, from: data))?.error
                throw APIError.http(status: http.statusCode, message: message)
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error)
        }
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var request = URLRequest(url: makeURL(path: path, query: query))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request, decoding: T.self)
    }

    func post<Body: Encodable, T: Decodable>(_ path: String, body: Body, query: [URLQueryItem] = []) async throws -> T {
        var request = URLRequest(url: makeURL(path: path, query: query))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.encoder.encode(body)
        return try await send(request, decoding: T.self)
    }

    func put<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: makeURL(path: path, query: []))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.encoder.encode(body)
        return try await send(request, decoding: T.self)
    }

    func delete(_ path: String, query: [URLQueryItem] = []) async throws {
        var request = URLRequest(url: makeURL(path: path, query: query))
        request.httpMethod = "DELETE"
        try await sendVoid(request)
    }

    func postNoBody<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: makeURL(path: path, query: []))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request, decoding: T.self)
    }
}

struct EmptyResponse: Decodable {}

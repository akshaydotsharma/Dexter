import Foundation

enum APIError: LocalizedError {
    case invalidResponse
    case http(status: Int, message: String?)
    case decoding(Error)
    case transport(Error)
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Server returned an unexpected response."
        case .http(let status, let message):
            return message ?? "Server returned status \(status)."
        case .decoding(let err):
            return "Could not parse server response. \(err.localizedDescription)"
        case .transport(let err):
            return err.localizedDescription
        case .notFound:
            return "Item not found."
        }
    }
}

struct APIErrorPayload: Decodable {
    let error: String?
}

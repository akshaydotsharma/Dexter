import Foundation

/// Read-only on-disk JSON cache for API responses.
///
/// Each view model reads from the cache during `init` so the surface paints
/// stale data on the very first frame, then refreshes from the API in the
/// background. The cache is never authoritative — it's a snapshot of the most
/// recent successful fetch. Writes go straight to the API; the cache is updated
/// after a successful refresh.
///
/// Files live in `Caches/api-cache/<key>.json`. The system may evict caches
/// under storage pressure, which is fine — next fetch repopulates.
///
/// We use plain JSON files instead of SwiftData @Model classes because the
/// data is read-only, the volumes are small (a single user's todos/notes/
/// lists/stats), and JSON keeps the interop with the API codecs zero-friction.
/// If we ever need live queries, on-device search, or schema migrations, this
/// can be swapped to SwiftData without touching the call sites.
enum CacheStore {
    enum Key: String {
        case todos
        case notes
        case noteFolders = "note_folders"
        case lists
        case dashboardStats = "dashboard_stats"
    }

    private static let baseURL: URL = {
        let dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("api-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func load<T: Decodable>(_ type: T.Type, from key: Key) -> T? {
        let url = baseURL.appendingPathComponent("\(key.rawValue).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? APIClient.decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to key: Key) {
        let url = baseURL.appendingPathComponent("\(key.rawValue).json")
        do {
            let data = try APIClient.encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            // Cache is best-effort. A failure here is not user-visible —
            // the next fetch will overwrite or repopulate.
        }
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: baseURL)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }
}

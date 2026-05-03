import Foundation

/// Read-only on-disk JSON cache for derived API responses.
///
/// Scope shrank with #14: todos, notes, lists, and folders moved to the
/// SwiftData store (`SwiftDataStore`) which is the authoritative on-device
/// source. CacheStore now exists only for derived/aggregated payloads
/// (currently just the dashboard stats), where the iOS app simply mirrors
/// what the server computes and a cache eviction is recoverable on the
/// next fetch.
///
/// Files live in `Caches/api-cache/<key>.json`. The system may evict
/// caches under storage pressure, which is fine — next fetch repopulates.
enum CacheStore {
    enum Key: String {
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

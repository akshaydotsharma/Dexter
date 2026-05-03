import Foundation

/// UserDefaults-backed watermark for the sync engine. Stores the highest
/// `version` the iOS client has seen from the server. The next pull asks
/// `/api/sync/changes?since_version=<watermark>`.
enum SyncWatermark {
    // Bumped to v2 when notes/lists/folders joined the SwiftData store —
    // previously-installed builds had a high watermark from todos-only
    // pulls, so the new build was asking the server for "changes since N"
    // and missing the historical notes/lists rows. v2 forces a single
    // full re-pull on first launch after upgrade.
    private static let key = "sync.lastVersion.v2"

    static var current: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: key)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: key) }
    }

    /// Bump only if the new value is strictly greater. Safe to call from
    /// concurrent push/pull paths.
    static func advance(to candidate: Int64) {
        if candidate > current {
            current = candidate
        }
    }

    /// Reset for tests or "log out + clear" flows.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

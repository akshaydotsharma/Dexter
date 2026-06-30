import Foundation

/// How often an automatic backup runs when the app is opened.
///
/// The cadence is best-effort: iOS won't reliably wake a closed app on a
/// timer, so `daily` / `weekly` fire the next time the app becomes active
/// after the interval has elapsed (see `BackupSettings.isDue(...)`).
enum BackupFrequency: String, CaseIterable, Identifiable {
    case everyLaunch
    case daily
    case weekly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .everyLaunch: return "Every launch"
        case .daily:       return "Daily"
        case .weekly:      return "Weekly"
        }
    }

    /// Minimum elapsed time since the last backup before another is due.
    /// `everyLaunch` returns 0 so a backup runs every time it's triggered.
    var minimumInterval: TimeInterval {
        switch self {
        case .everyLaunch: return 0
        case .daily:       return 24 * 60 * 60
        case .weekly:      return 7 * 24 * 60 * 60
        }
    }
}

/// Single source of truth for the backup feature's persisted settings.
///
/// Backed by `UserDefaults` so both SwiftUI (`@AppStorage`, keyed by the
/// same strings) and the non-View `BackupService` read and write the same
/// values. The View owns the live bindings; the service reads the snapshot
/// when a scene-phase or manual trigger fires.
enum BackupSettings {
    enum Key {
        static let enabled         = "backup.enabled"
        static let frequency       = "backup.frequency"
        static let folderBookmark  = "backup.folderBookmark"
        static let folderName      = "backup.folderName"
        static let lastBackupAt    = "backup.lastBackupAt"
        static let lastFileName    = "backup.lastFileName"
        static let lastError       = "backup.lastError"
    }

    /// Rolling backup file name. One file per folder, overwritten each run,
    /// so the iCloud-synced folder never accumulates stale snapshots.
    static let fileName = "Dexter-Backup.zip"

    private static var defaults: UserDefaults { .standard }

    // MARK: - Typed accessors

    static var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    static var frequency: BackupFrequency {
        get { BackupFrequency(rawValue: defaults.string(forKey: Key.frequency) ?? "") ?? .daily }
        set { defaults.set(newValue.rawValue, forKey: Key.frequency) }
    }

    static var folderBookmark: Data? {
        get { defaults.data(forKey: Key.folderBookmark) }
        set { defaults.set(newValue, forKey: Key.folderBookmark) }
    }

    static var folderName: String? {
        get { defaults.string(forKey: Key.folderName) }
        set { defaults.set(newValue, forKey: Key.folderName) }
    }

    static var lastBackupAt: Date? {
        get {
            let t = defaults.double(forKey: Key.lastBackupAt)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.lastBackupAt) }
    }

    static var lastFileName: String? {
        get { defaults.string(forKey: Key.lastFileName) }
        set { defaults.set(newValue, forKey: Key.lastFileName) }
    }

    static var lastError: String? {
        get { defaults.string(forKey: Key.lastError) }
        set { defaults.set(newValue, forKey: Key.lastError) }
    }

    // MARK: - Derived

    /// Whether a non-forced run should proceed: enabled, a folder is set,
    /// and enough time has passed since the last successful backup.
    static func isDue(now: Date = Date()) -> Bool {
        guard enabled, folderBookmark != nil else { return false }
        guard let last = lastBackupAt else { return true }
        return now.timeIntervalSince(last) >= frequency.minimumInterval
    }
}

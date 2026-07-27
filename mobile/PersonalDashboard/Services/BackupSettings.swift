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

    /// Rolling backup file name, scoped to THIS device.
    ///
    /// One file per device per folder, overwritten each run, so a folder never
    /// accumulates stale snapshots but two devices never fight over one name.
    ///
    /// ⚠️ This used to be a single shared constant, `Dexter-Backup.zip`, which was
    /// correct only while one device wrote to the folder. Sync now encourages both
    /// the Mac and the phone to point at the SAME folder (#348 reuses the backup
    /// bookmark by design), and within minutes of enabling it on both, the field
    /// showed exactly what you would expect (#354):
    ///
    ///     Dexter-Backup.zip
    ///     Dexter-Backup 2.zip     <- iCloud conflict copy
    ///
    /// That is worse than untidy. This file is the recovery path #349 exists to
    /// verify, and the whole phase 2 safety argument rests on it. Two devices
    /// overwriting one name means the file may hold the OTHER device's data at any
    /// moment, and once iCloud forks it neither the current copy nor its origin
    /// device is knowable from the name. A restore then cannot be aimed
    /// confidently. Per-device names make each snapshot self-identifying.
    ///
    /// The legacy name is still recognised on restore, because the user's existing
    /// `Dexter-Backup.zip` is a real recovery artefact and must keep working.
    static var fileName: String {
        "Dexter-Backup-\(deviceFileNameComponent()).zip"
    }

    /// The pre-#354 shared name. Never written again; recognised so an existing
    /// archive stays restorable.
    static let legacyFileName = "Dexter-Backup.zip"

    /// Device label, reduced to something safe for a filename.
    ///
    /// Filesystem-hostile characters are stripped rather than escaped so the name
    /// stays readable in Finder and the Files app, which is the whole point of
    /// making it per-device. Falls back to a fixed string if a name reduces to
    /// nothing, so the filename can never collapse to `Dexter-Backup-.zip`.
    static func deviceFileNameComponent() -> String {
        let raw = SyncDeviceNaming.currentDeviceName()
        let allowed = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "Device" : collapsed
    }

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

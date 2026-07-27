import Foundation

// The shared-folder transport for sync (#348).
//
// Sync has no server and no CloudKit entitlement. What it has is a folder the
// user picked with the document picker, which iOS and macOS sync through iCloud
// Drive on our behalf. `BackupService` already established that this works and
// carries a security-scoped bookmark for it; sync reuses the same folder by
// default and lays its own subtree inside it.
//
// Layout:
//
//   <picked folder>/
//     Dexter-Backup.zip              <- BackupService, untouched by sync
//     DexterSync-<deviceUUID>/       <- created ONLY by the device it names
//       meta.json                    <- mutable HINT, may fork, never trusted
//       seg-000001.json              <- sealed, immutable
//       seg-000002.json
//
// THE RULE: A DEVICE NEVER CREATES A PATH THAT ANOTHER DEVICE ALSO CREATES.
// Not just files. Directories too.
//
// ⚠️ The layout is flat because the obvious nested one is broken (#353). The first
// version used `DexterSync/devices/<deviceUUID>/`, on the reasoning that
// per-device leaf directories meant iCloud only ever had new files to upload and
// never a merge to attempt. That was right about files and wrong about
// directories: `createDirectory(withIntermediateDirectories: true)` had BOTH
// devices independently create the shared ancestors `DexterSync/` and
// `DexterSync/devices/`, and iCloud forks two independently created directories at
// one path exactly as it forks two files. In the field it produced:
//
//     DexterSync/devices/     <- the phone's branch
//     DexterSync/devices 2/   <- the Mac's branch, holding the Mac's segments
//
// after which each device read only its own branch and neither ever saw a peer,
// while both reported a healthy folder and a full op count. Worse, the Mac's log
// split across the two branches, so even finding one branch gave a partial log.
//
// Putting the device id in the TOP-LEVEL directory name makes the only shared
// ancestor the user-picked folder itself, which the user created and which sync
// never creates. No shared path is left for iCloud to fork.

// MARK: - Settings

/// Persisted settings for sync. Separate from `BackupSettings` so the two
/// features can be pointed at different folders.
///
/// `folderBookmark` is nil by default and falls back to the backup folder. That
/// gives one folder pick for normal use, while still allowing phase 2 device
/// testing to aim sync at a throwaway folder without disturbing the real backup
/// (which is the recovery path, so it must keep working untouched).
enum SyncSettings {
    enum Key {
        static let enabled        = "sync.enabled"
        static let folderBookmark = "sync.folderBookmark"
        static let folderName     = "sync.folderName"
    }

    private static var defaults: UserDefaults { .standard }

    static var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Dedicated sync folder. Nil means "use the backup folder".
    static var folderBookmark: Data? {
        get { defaults.data(forKey: Key.folderBookmark) }
        set { defaults.set(newValue, forKey: Key.folderBookmark) }
    }

    static var folderName: String? {
        get { defaults.string(forKey: Key.folderName) }
        set { defaults.set(newValue, forKey: Key.folderName) }
    }
}

// MARK: - Health

/// What the status UI shows about folder access.
///
/// A silently stale bookmark is a known failure mode of this transport: sync
/// just stops, with no error anywhere. Modelling health as an explicit enum
/// rather than an optional URL is what forces the UI to render the difference
/// between "no folder chosen", "folder chosen but no longer reachable", and
/// "working".
enum SyncFolderHealth: Equatable {
    case notConfigured
    case valid(name: String, usingBackupFolder: Bool)
    case stale(name: String)
    case accessDenied(name: String)
    case failed(String)

    var isUsable: Bool {
        if case .valid = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .notConfigured:
            return "No folder selected"
        case .valid(let name, let usingBackup):
            return usingBackup ? "\(name) (shared with backup)" : name
        case .stale(let name):
            return "\(name) — access expired, pick it again"
        case .accessDenied(let name):
            return "\(name) — access denied, pick it again"
        case .failed(let message):
            return "Unavailable: \(message)"
        }
    }
}

// MARK: - Folder

enum SyncFolderError: LocalizedError {
    case notConfigured
    case accessDenied
    case bookmarkResolveFailed(Error)
    case segmentAlreadyExists(Int)
    case decodeFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No sync folder is configured."
        case .accessDenied:
            return "Couldn't access the sync folder. Pick it again to re-grant access."
        case .bookmarkResolveFailed(let error):
            return "Couldn't open the sync folder: \(error.localizedDescription)"
        case .segmentAlreadyExists(let sequence):
            return "Segment \(sequence) already exists. Refusing to overwrite a sealed segment."
        case .decodeFailed(let name, let error):
            return "Couldn't read \(name): \(error.localizedDescription)"
        }
    }
}

/// Resolved handle onto the shared folder. Deliberately not actor-isolated: all
/// of this is file IO and runs off the main actor from `SyncEngine`.
struct SyncFolder {
    let root: URL
    let usingBackupFolder: Bool
    let displayName: String

    /// Prefix for a device's own directory: `DexterSync-<deviceUUID>`.
    static let deviceDirectoryPrefix = "DexterSync-"
    /// The old nested root (#353). Never written again, only recognised so the UI
    /// can tell the user it is dead weight and safe to delete.
    static let legacySubdirectoryName = "DexterSync"
    static let metaFileName = "meta.json"
    private static let segmentPrefix = "seg-"
    private static let segmentSuffix = ".json"

    // MARK: Resolution

    /// Resolve the configured folder, preferring a dedicated sync folder and
    /// falling back to the backup folder.
    ///
    /// ⚠️ This duplicates ~20 lines of bookmark handling from `BackupService`
    /// rather than sharing them, ON PURPOSE. During sync development the backup
    /// is the user's only recovery path, so the code that produces it stays
    /// untouched. Refactoring the two together is a fine cleanup once sync is
    /// trusted, and a bad idea before then.
    static func resolve() throws -> SyncFolder {
        let usingBackup = SyncSettings.folderBookmark == nil
        guard let bookmark = SyncSettings.folderBookmark ?? BackupSettings.folderBookmark else {
            throw SyncFolderError.notConfigured
        }
        let name = (usingBackup ? BackupSettings.folderName : SyncSettings.folderName) ?? "Sync folder"

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw SyncFolderError.bookmarkResolveFailed(error)
        }

        if isStale {
            // Re-mint while we still hold a resolved URL, so the next launch
            // doesn't fail outright. Needs a scope to read the URL.
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            if let refreshed = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                if usingBackup {
                    BackupSettings.folderBookmark = refreshed
                } else {
                    SyncSettings.folderBookmark = refreshed
                }
            }
        }

        return SyncFolder(root: url, usingBackupFolder: usingBackup, displayName: name)
    }

    /// Non-throwing health probe for the status UI.
    static func health() -> SyncFolderHealth {
        guard SyncSettings.folderBookmark != nil || BackupSettings.folderBookmark != nil else {
            return .notConfigured
        }
        do {
            let folder = try resolve()
            guard folder.beginAccess() else {
                return .accessDenied(name: folder.displayName)
            }
            defer { folder.endAccess() }
            // Reachability is the real test. A bookmark can resolve to a URL
            // that no longer exists (folder deleted or moved in iCloud Drive),
            // which is exactly the silent-stop case worth surfacing.
            let reachable = (try? folder.root.checkResourceIsReachable()) ?? false
            guard reachable else { return .stale(name: folder.displayName) }
            return .valid(name: folder.displayName, usingBackupFolder: folder.usingBackupFolder)
        } catch let error as SyncFolderError {
            switch error {
            case .notConfigured: return .notConfigured
            default: return .failed(error.errorDescription ?? "unknown")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Security scope

    /// `startAccessingSecurityScopedResource` is a ref-counted claim on the URL
    /// for the whole process, not a thread-local one, so a scope opened here can
    /// legitimately be held across an `await` and used from another executor.
    /// `BackupService` relies on the same property.
    @discardableResult
    func beginAccess() -> Bool {
        root.startAccessingSecurityScopedResource()
    }

    func endAccess() {
        root.stopAccessingSecurityScopedResource()
    }

    // MARK: Paths

    /// The pre-#353 nested root. Sync never reads or writes it; this exists only
    /// so the status UI can point at what the user may delete.
    var legacyRoot: URL { root.appendingPathComponent(Self.legacySubdirectoryName, isDirectory: true) }

    static func directoryName(for deviceUUID: UUID) -> String {
        deviceDirectoryPrefix + deviceUUID.uuidString
    }

    /// Parse a device id out of a directory name, rejecting anything that is not
    /// exactly `DexterSync-<uuid>`.
    ///
    /// The strict UUID parse is what makes an iCloud conflict copy
    /// ("DexterSync-<uuid> 2") get ignored rather than adopted as a third phantom
    /// device. Each device now only ever creates its own directory, so a conflict
    /// copy should not arise, but a folder that predates #353 can still hold one.
    static func deviceUUID(fromDirectoryName name: String) -> UUID? {
        guard name.hasPrefix(deviceDirectoryPrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(deviceDirectoryPrefix.count)))
    }

    func deviceDirectory(_ deviceUUID: UUID) -> URL {
        root.appendingPathComponent(Self.directoryName(for: deviceUUID), isDirectory: true)
    }

    func metaURL(_ deviceUUID: UUID) -> URL {
        deviceDirectory(deviceUUID).appendingPathComponent(Self.metaFileName)
    }

    func segmentURL(_ deviceUUID: UUID, sequence: Int) -> URL {
        deviceDirectory(deviceUUID).appendingPathComponent(Self.segmentFileName(sequence))
    }

    static func segmentFileName(_ sequence: Int) -> String {
        // Zero-padded so a plain lexicographic directory listing is also
        // chronological, which makes the log readable by eye in Finder.
        String(format: "%@%06d%@", segmentPrefix, sequence, segmentSuffix)
    }

    static func sequence(fromFileName name: String) -> Int? {
        guard name.hasPrefix(segmentPrefix), name.hasSuffix(segmentSuffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: segmentPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -segmentSuffix.count)
        // Rejects iCloud conflict copies ("seg-000003 2.json") because the
        // middle no longer parses as an integer. Silently ignoring them is
        // correct: the original is still present and authoritative.
        return Int(name[start..<end])
    }

    func ensureDirectories(for deviceUUID: UUID) throws {
        try FileManager.default.createDirectory(
            at: deviceDirectory(deviceUUID),
            withIntermediateDirectories: true
        )
    }

    // MARK: Writing

    /// Write a sealed segment. Refuses to overwrite an existing sequence.
    ///
    /// The refusal matters because one user-global SwiftData store is shared by
    /// every worktree and agent on this Mac, so two app instances can genuinely
    /// hold the same device identity and the same sequence counter at once.
    /// Clobbering a sealed segment would drop ops the peer had not yet read.
    func writeSegment(_ segment: SyncSegment) throws {
        try ensureDirectories(for: segment.deviceUUID)
        let destination = segmentURL(segment.deviceUUID, sequence: segment.sequence)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SyncFolderError.segmentAlreadyExists(segment.sequence)
        }
        let data = try DataArchive.makeEncoder().encode(segment)
        try coordinatedWrite(data, to: destination, replacing: false)
    }

    /// Write the per-device pointer file. This is the only mutable file sync
    /// writes, hence the only one that can fork into a conflict copy. Nothing
    /// reads it as truth.
    func writeMeta(_ meta: SyncDeviceMeta) throws {
        try ensureDirectories(for: meta.deviceUUID)
        let data = try DataArchive.makeEncoder().encode(meta)
        try coordinatedWrite(data, to: metaURL(meta.deviceUUID), replacing: true)
    }

    private func coordinatedWrite(_ data: Data, to destination: URL, replacing: Bool) throws {
        try Self.coordinatedWrite(data, to: destination, replacing: replacing)
    }

    /// `static` and free of instance state so a caller on the main actor can hop
    /// this onto a detached task. The first outbound pass emits every record in
    /// the store, so this write can be multi-megabyte on a real device: doing it
    /// inline would be a visible hang on the launch that enables sync. Same
    /// reasoning, and the same shape, as `BackupService.writeCoordinated`.
    ///
    /// `Data` and `URL` are the only things crossing the executor boundary,
    /// which is what makes the hop safe without any actor annotation.
    static func coordinatedWrite(_ data: Data, to destination: URL, replacing: Bool) throws {
        var coordinatorError: NSError?
        var thrownError: Error?
        let coordinator = NSFileCoordinator()

        coordinator.coordinate(
            writingItemAt: destination,
            options: replacing ? .forReplacing : [],
            error: &coordinatorError
        ) { url in
            do {
                // `.atomic` stages to a temp file and renames, so iCloud never
                // observes a half-written segment and starts uploading it.
                try data.write(to: url, options: .atomic)
            } catch {
                thrownError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let thrownError { throw thrownError }
    }

    // MARK: Reading

    /// Device directories present in the picked folder, excluding this device.
    ///
    /// Enumerates the user-picked folder directly. There is deliberately no
    /// intermediate directory to walk: an intermediate directory would have to be
    /// created by every device, and that is exactly what iCloud forked in #353.
    func peerDeviceUUIDs(excluding selfUUID: UUID) throws -> [UUID] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return entries.compactMap { url in
            guard let uuid = Self.deviceUUID(fromDirectoryName: url.lastPathComponent),
                  uuid != selfUUID else { return nil }
            return uuid
        }.sorted { $0.uuidString < $1.uuidString }
    }

    /// Whether a pre-#353 `DexterSync/` tree is still sitting in the folder.
    /// Surfaced so the user can delete it; sync never reads or writes it.
    func hasLegacyLayout() -> Bool {
        FileManager.default.fileExists(atPath: legacyRoot.path)
    }

    /// Sealed segment sequences present for a device, ascending.
    ///
    /// This is the authoritative view of a peer's log. `meta.json` is only a
    /// hint, so anything that needs to know what actually exists asks here.
    func segmentSequences(for deviceUUID: UUID) throws -> [Int] {
        let directory = deviceDirectory(deviceUUID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries.compactMap { Self.sequence(fromFileName: $0.lastPathComponent) }.sorted()
    }

    func readSegment(deviceUUID: UUID, sequence: Int) throws -> SyncSegment {
        let url = segmentURL(deviceUUID, sequence: sequence)
        let data = try coordinatedRead(url)
        do {
            return try DataArchive.makeDecoder().decode(SyncSegment.self, from: data)
        } catch {
            throw SyncFolderError.decodeFailed(url.lastPathComponent, error)
        }
    }

    /// Best-effort read of a peer's pointer file. Returns nil rather than
    /// throwing: a missing or forked `meta.json` is not an error, because the
    /// segments are the truth.
    func readMeta(deviceUUID: UUID) -> SyncDeviceMeta? {
        guard let data = try? coordinatedRead(metaURL(deviceUUID)) else { return nil }
        return try? DataArchive.makeDecoder().decode(SyncDeviceMeta.self, from: data)
    }

    private func coordinatedRead(_ url: URL) throws -> Data {
        var coordinatorError: NSError?
        var thrownError: Error?
        var result: Data?
        let coordinator = NSFileCoordinator()

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            do {
                result = try Data(contentsOf: readURL)
            } catch {
                thrownError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let thrownError { throw thrownError }
        guard let result else {
            throw CocoaError(.fileReadUnknown)
        }
        return result
    }

    // MARK: iCloud materialisation

    /// Ensure a file's bytes are actually on this device before reading it.
    ///
    /// Files in iCloud Drive can be present in a directory listing while their
    /// contents live only in the cloud. Reading one without this step fails in a
    /// way that looks exactly like a missing or corrupt segment, which would
    /// otherwise get misdiagnosed as a sync bug.
    ///
    /// Returns false on timeout. The caller treats that as "not yet available,
    /// try next pass" rather than an error, because that is what it is.
    static func materialize(_ url: URL, timeout: TimeInterval = 20) async -> Bool {
        if isMaterialized(url) { return true }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            // Not a ubiquitous item (folder outside iCloud Drive, or a plain
            // local folder used for testing). If it exists, it is readable.
            return FileManager.default.fileExists(atPath: url.path)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isMaterialized(url) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isMaterialized(url)
    }

    private static func isMaterialized(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if let status = values?.ubiquitousItemDownloadingStatus {
            return status == .current || status == .downloaded
        }
        // No downloading status means the item is not cloud-backed at all, so
        // plain existence is the right answer.
        return FileManager.default.fileExists(atPath: url.path)
    }
}

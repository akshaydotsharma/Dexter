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
//       assets/                      <- attachment bytes (#471)
//         man-000001.json            <- sealed, immutable: path -> content hash
//         <sha256>.jpg               <- the blob, named for its own contents
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
        static let applyEnabled   = "sync.applyEnabled"
        static let folderBookmark = "sync.folderBookmark"
        static let folderName     = "sync.folderName"
    }

    private static var defaults: UserDefaults { .standard }

    /// DEBUG-only env overrides, completing the isolation `DEXTER_SYNC_FOLDER`
    /// started (#356).
    ///
    /// Without these a harness still has to `defaults write` the toggles on the
    /// app's own bundle id to test anything, which is the exact mechanism that
    /// polluted a real store with phantom peers. Env-only, never persisted, inert
    /// in Release. A folder override implies sync is on, since pointing a run at a
    /// scratch folder has no other purpose.
    #if DEBUG
    private static func envFlag(_ name: String) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return false }
        return !["0", "false", "no", ""].contains(raw.lowercased())
    }
    static var hasFolderOverride: Bool {
        ProcessInfo.processInfo.environment["DEXTER_SYNC_FOLDER"] != nil
    }
    #endif

    static var enabled: Bool {
        get {
            #if DEBUG
            if hasFolderOverride { return true }
            #endif
            return defaults.bool(forKey: Key.enabled)
        }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Phase 2: actually apply a peer's changes (#359).
    ///
    /// Deliberately SEPARATE from `enabled`, and off by default. Publishing your
    /// own log is harmless; applying someone else's changes is the first thing in
    /// this feature that can destroy data. Keeping them apart means outbound-only
    /// stays available, and turning applying on is an explicit, revocable act
    /// rather than a side effect of enabling sync.
    static var applyEnabled: Bool {
        get {
            #if DEBUG
            if hasFolderOverride { return envFlag("DEXTER_SYNC_APPLY") }
            #endif
            return defaults.bool(forKey: Key.applyEnabled)
        }
        set { defaults.set(newValue, forKey: Key.applyEnabled) }
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
    case disposableStoreNeedsOverrideFolder
    case bookmarkResolveFailed(Error)
    case segmentAlreadyExists(Int)
    case decodeFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No sync folder is configured."
        case .accessDenied:
            return "Couldn't access the sync folder. Pick it again to re-grant access."
        case .disposableStoreNeedsOverrideFolder:
            return "This launch uses a disposable store (DEXTER_STORE_PATH), so sync "
                + "refuses to touch the configured folder. Set DEXTER_SYNC_FOLDER too "
                + "if this run is meant to sync." 
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
    /// False for a `DEXTER_SYNC_FOLDER` override, which is a plain local path.
    ///
    /// `startAccessingSecurityScopedResource()` returns FALSE for a URL that was
    /// not minted from a bookmark, and the callers treat false as access-denied.
    /// Without this flag the debug override would resolve fine and then be
    /// rejected as unreachable on the very next line.
    var isSecurityScoped: Bool = true

    /// Prefix for a device's own directory: `DexterSync-<deviceUUID>`.
    static let deviceDirectoryPrefix = "DexterSync-"
    /// The old nested root (#353). Never written again, only recognised so the UI
    /// can tell the user it is dead weight and safe to delete.
    static let legacySubdirectoryName = "DexterSync"
    static let metaFileName = "meta.json"
    private static let segmentPrefix = "seg-"
    private static let segmentSuffix = ".json"
    /// Attachment blobs and their manifests (#471), INSIDE the device's own
    /// directory. See `assetsDirectory` for why it may not live any higher up.
    static let assetsDirectoryName = "assets"
    private static let manifestPrefix = "man-"

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
        #if DEBUG
        // Env-only scratch folder for automated verification (#356).
        //
        // This exists because the alternative was actively harmful. A harness with
        // no override has to fake a folder by writing `sync.folderBookmark` and
        // `sync.enabled` with `defaults write` on the app's bundle id — which is
        // the SAME preferences domain the real app reads. A running instance then
        // adopts the scratch folder, publishes the user's real store into it, and
        // records the harness's scratch devices as permanent peers. That happened,
        // and it left two phantom "MacBook Pro" peers in a real store.
        //
        // Env-only and never persisted, so a stale value cannot outlive the run
        // that set it. Mirrors `DEXTER_STORE_PATH`, which exists for the same
        // reason on the store side. Inert in Release.
        if let raw = ProcessInfo.processInfo.environment["DEXTER_SYNC_FOLDER"],
           !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                fatalError("""
                    DEXTER_SYNC_FOLDER is set to \(url.path) but that folder does \
                    not exist. Refusing to launch rather than silently syncing to \
                    the real configured folder.
                    """)
            }
            NSLog("SyncFolder: using OVERRIDE sync folder at %@ (DEXTER_SYNC_FOLDER)", url.path)
            return SyncFolder(
                root: url,
                usingBackupFolder: false,
                displayName: url.lastPathComponent,
                isSecurityScoped: false
            )
        }
        #endif

        #if DEBUG
        // A DISPOSABLE STORE MUST NEVER PUBLISH TO THE REAL SHARED FOLDER.
        //
        // `DEXTER_STORE_PATH` declares this run's data throwaway. Sync reads its
        // folder from persisted settings, though, so without this guard a
        // scratch-store launch happily published into whatever folder the user has
        // configured. It did: two phantom "MacBook Pro" device directories landed
        // in a real iCloud folder from harness runs that set a store override but
        // no folder override.
        //
        // Tidiness was the least of it. Once phase 2 applying is on, a scratch
        // store's ops get APPLIED to real data, so a test that deletes a record
        // would propagate that delete to the user's live device. The two dirs in
        // question happened to carry zero delete ops; that was luck, not design.
        //
        // A run that wants both a scratch store and sync must say so by also
        // setting DEXTER_SYNC_FOLDER, which is handled above. Reaching here with an
        // override store means the caller did not, so refuse rather than guess.
        // Read the env var rather than `SwiftDataStore.isUsingOverrideStore`:
        // that static is main-actor isolated and `resolve()` is deliberately not,
        // because it is all file IO. The variable is what set the override in the
        // first place, so this is the same fact reached from a safe angle.
        if ProcessInfo.processInfo.environment["DEXTER_STORE_PATH"] != nil {
            throw SyncFolderError.disposableStoreNeedsOverrideFolder
        }
        #endif

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
        #if DEBUG
        let hasOverride = ProcessInfo.processInfo.environment["DEXTER_SYNC_FOLDER"] != nil
        #else
        let hasOverride = false
        #endif
        guard hasOverride || SyncSettings.folderBookmark != nil || BackupSettings.folderBookmark != nil else {
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
        guard isSecurityScoped else { return true }
        return root.startAccessingSecurityScopedResource()
    }

    func endAccess() {
        guard isSecurityScoped else { return }
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

    // MARK: Attachment assets (#471)

    /// Where a device publishes its attachment blobs and their manifests.
    ///
    /// ⚠️ NESTED INSIDE THE DEVICE'S OWN DIRECTORY, and it has to stay there. A
    /// shared `<picked folder>/blobs/` would be created independently by every
    /// device, which is precisely the shape iCloud forked in #353 — two devices
    /// each creating one directory at one path produced `devices/` and
    /// `devices 2/`, and each device then read only its own branch while both
    /// reported a healthy folder. `DexterSync-<uuid>/assets/` has exactly one
    /// creator, so THE RULE at the top of this file still holds: no path here is
    /// ever created by two devices.
    func assetsDirectory(_ deviceUUID: UUID) -> URL {
        deviceDirectory(deviceUUID)
            .appendingPathComponent(Self.assetsDirectoryName, isDirectory: true)
    }

    /// A blob, named for the SHA-256 of its own contents.
    ///
    /// Content addressing buys three things at once: re-publishing is idempotent
    /// (the name is already there, so nothing is written), the same bytes attached
    /// twice cost one copy, and a peer can verify what it downloaded against the
    /// name it asked for before writing it into the user's Documents. The
    /// extension rides along so the file is still recognisable by eye in Finder.
    func blobURL(_ deviceUUID: UUID, blobName: String) -> URL {
        assetsDirectory(deviceUUID).appendingPathComponent(blobName)
    }

    func assetManifestURL(_ deviceUUID: UUID, sequence: Int) -> URL {
        assetsDirectory(deviceUUID)
            .appendingPathComponent(Self.manifestFileName(sequence))
    }

    static func manifestFileName(_ sequence: Int) -> String {
        String(format: "%@%06d%@", manifestPrefix, sequence, segmentSuffix)
    }

    /// Rejects iCloud conflict copies ("man-000003 2.json") the same way
    /// `sequence(fromFileName:)` does, and for the same reason.
    static func manifestSequence(fromFileName name: String) -> Int? {
        guard name.hasPrefix(manifestPrefix), name.hasSuffix(segmentSuffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: manifestPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -segmentSuffix.count)
        return Int(name[start..<end])
    }

    func ensureAssetsDirectory(for deviceUUID: UUID) throws {
        try FileManager.default.createDirectory(
            at: assetsDirectory(deviceUUID),
            withIntermediateDirectories: true
        )
    }

    /// Manifest sequences published by a device, ascending.
    ///
    /// The manifests ARE the index. Nothing durable is kept on this side of the
    /// wire about which blob holds which attachment: a device that wants a file
    /// re-reads the peers' manifests on the pass that needs it. That is what lets
    /// a failed or deferred fetch retry for free next pass instead of needing a
    /// queue in the store, and it means asset transfer added no `@Model` at all.
    func assetManifestSequences(for deviceUUID: UUID) throws -> [Int] {
        let directory = assetsDirectory(deviceUUID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries.compactMap { Self.manifestSequence(fromFileName: $0.lastPathComponent) }.sorted()
    }

    func readAssetManifest(deviceUUID: UUID, sequence: Int) throws -> SyncAssetManifest {
        let url = assetManifestURL(deviceUUID, sequence: sequence)
        let data = try coordinatedRead(url)
        do {
            return try DataArchive.makeDecoder().decode(SyncAssetManifest.self, from: data)
        } catch {
            throw SyncFolderError.decodeFailed(url.lastPathComponent, error)
        }
    }

    /// Seal a manifest. Refuses to overwrite one, exactly as `writeSegment` does:
    /// a rewritten manifest is a mutable file, and a mutable file is the one thing
    /// iCloud will fork.
    func writeAssetManifest(_ manifest: SyncAssetManifest) throws {
        try ensureAssetsDirectory(for: manifest.deviceUUID)
        let destination = assetManifestURL(manifest.deviceUUID, sequence: manifest.sequence)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SyncFolderError.segmentAlreadyExists(manifest.sequence)
        }
        let data = try DataArchive.makeEncoder().encode(manifest)
        try Self.coordinatedWrite(data, to: destination, replacing: false)
    }

    /// Publish one blob. Returns false when the name was already there, which is
    /// the ordinary outcome for content-addressed bytes and not an error.
    @discardableResult
    func writeBlob(_ data: Data, deviceUUID: UUID, blobName: String) throws -> Bool {
        try ensureAssetsDirectory(for: deviceUUID)
        let destination = blobURL(deviceUUID, blobName: blobName)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }
        try Self.coordinatedWrite(data, to: destination, replacing: false)
        return true
    }

    /// Blob names this device has on disk. Names only, so this stays one cheap
    /// directory read however large the blobs are.
    func blobNames(for deviceUUID: UUID) -> Set<String> {
        let directory = assetsDirectory(deviceUUID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return Set(names.filter { Self.manifestSequence(fromFileName: $0) == nil && !$0.hasPrefix(".") })
    }

    func deleteBlob(deviceUUID: UUID, blobName: String) throws {
        let url = blobURL(deviceUUID, blobName: blobName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func readBlob(_ url: URL) throws -> Data {
        try coordinatedRead(url)
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

        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        while Date() < deadline {
            if isMaterialized(url) {
                // Logged because this number is the only way to tell iCloud being
                // slow from a bug in this code. Without it a pass that waited
                // three seconds and one that found the file already local are
                // indistinguishable, and so are a slow delivery and a broken
                // reader (#451).
                SyncLog.line(String(
                    format: "SyncFolder: %@ materialised after %.1fs",
                    url.lastPathComponent, Date().timeIntervalSince(started)
                ))
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isMaterialized(url)
    }

    /// Ask iCloud to start downloading every one of these, without waiting.
    ///
    /// The reader applies segments strictly in sequence order, so it can only
    /// consume the first one that is actually down. That is correct, but on its
    /// own it means nothing ever asks for the SECOND segment until the first has
    /// been applied — a peer several segments behind then needs one pass each,
    /// up to a poll interval apart. Requesting them all up front costs nothing
    /// and lets iCloud fetch them in parallel while we wait for the first (#451).
    ///
    /// Failures are ignored on purpose: a non-ubiquitous path (a plain folder in
    /// a test) or a file that is already local both throw here and both mean
    /// "nothing to download".
    static func requestDownloads(_ urls: [URL]) {
        for url in urls where !isMaterialized(url) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
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

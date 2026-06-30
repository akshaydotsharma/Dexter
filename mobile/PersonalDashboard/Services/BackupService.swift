import Foundation
import SwiftData

/// Writes an automatic, opt-in backup of the SwiftData store into a folder
/// the user picked in iCloud Drive (or anywhere the document picker grants
/// access to). We never touch CloudKit / iCloud entitlements — free
/// personal-team signing doesn't allow them. Instead the user grants access
/// to a folder via the document picker, we persist a SECURITY-SCOPED
/// BOOKMARK, and write a single rolling `.zip` into it. iOS syncs that folder
/// to iCloud transparently.
///
/// All reads/writes of the bookmarked URL are wrapped in
/// `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`
/// and the write goes through `NSFileCoordinator` so iCloud doesn't see a
/// half-written file.
@MainActor
final class BackupService {

    enum BackupError: LocalizedError {
        case noFolderSelected
        case folderAccessDenied
        case bookmarkResolveFailed(Error)
        case exportFailed(Error)
        case writeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noFolderSelected:
                return "Pick a backup folder first."
            case .folderAccessDenied:
                return "Couldn't access the backup folder. Pick it again to re-grant access."
            case .bookmarkResolveFailed(let e):
                return "Couldn't open the backup folder: \(e.localizedDescription)"
            case .exportFailed(let e):
                return (e as? LocalizedError)?.errorDescription ?? "Couldn't build the backup: \(e.localizedDescription)"
            case .writeFailed(let e):
                return "Couldn't save the backup: \(e.localizedDescription)"
            }
        }
    }

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Folder bookmark

    /// Persist a security-scoped bookmark for a folder the user just picked.
    /// `pickedURL` comes straight from the document picker and is still
    /// access-scoped at call time, so we open a scope to mint the bookmark.
    /// Returns the folder's display name for the UI.
    @discardableResult
    func saveFolder(_ pickedURL: URL) throws -> String {
        let didStart = pickedURL.startAccessingSecurityScopedResource()
        defer { if didStart { pickedURL.stopAccessingSecurityScopedResource() } }

        let bookmark = try pickedURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        BackupSettings.folderBookmark = bookmark
        BackupSettings.folderName = pickedURL.lastPathComponent
        return pickedURL.lastPathComponent
    }

    /// Resolve the stored bookmark back into a usable URL, refreshing it if
    /// iOS has marked it stale. The caller is responsible for opening a
    /// security scope on the returned URL before reading/writing.
    private func resolveFolderURL() throws -> URL {
        guard let bookmark = BackupSettings.folderBookmark else {
            throw BackupError.noFolderSelected
        }
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
            throw BackupError.bookmarkResolveFailed(error)
        }

        if isStale {
            // Re-mint the bookmark while we still have a resolved URL so the
            // next launch doesn't fail. Needs a scope to read the URL.
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            if let refreshed = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                BackupSettings.folderBookmark = refreshed
            }
        }
        return url
    }

    // MARK: - Run

    /// Run a backup if it's due (or always when `force` is true). Builds the
    /// zip via `DataExportService`, then writes it into the bookmarked folder
    /// through `NSFileCoordinator`. On success, updates `lastBackupAt` /
    /// `lastFileName` and clears any prior error.
    ///
    /// Throws on a forced run so the UI can surface the failure. A non-forced
    /// run that isn't due returns quietly without throwing.
    @discardableResult
    func runBackupIfDue(force: Bool) throws -> Bool {
        if !force && !BackupSettings.isDue() {
            return false
        }
        guard BackupSettings.folderBookmark != nil else {
            if force { throw BackupError.noFolderSelected }
            return false
        }

        // 1. Build the archive into the system temp dir.
        let tempURL: URL
        do {
            tempURL = try DataExportService(modelContext: modelContext).export()
        } catch {
            recordError(BackupError.exportFailed(error))
            throw BackupError.exportFailed(error)
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // 2. Resolve the destination folder and write atomically.
        let folderURL: URL
        do {
            folderURL = try resolveFolderURL()
        } catch {
            recordError(error)
            throw error
        }

        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }

        do {
            try writeCoordinated(from: tempURL, intoFolder: folderURL)
        } catch {
            recordError(BackupError.writeFailed(error))
            throw BackupError.writeFailed(error)
        }

        // 3. Record success.
        BackupSettings.lastBackupAt = Date()
        BackupSettings.lastFileName = BackupSettings.fileName
        BackupSettings.lastError = nil
        return true
    }

    /// Coordinated atomic write: stage the bytes into the destination folder
    /// under a temporary name, then `replaceItemAt` so iCloud never observes
    /// a partially written `Dexter-Backup.zip`.
    private func writeCoordinated(from sourceURL: URL, intoFolder folderURL: URL) throws {
        let destURL = folderURL.appendingPathComponent(BackupSettings.fileName)

        var coordinatorError: NSError?
        var thrownError: Error?
        let coordinator = NSFileCoordinator()

        coordinator.coordinate(
            writingItemAt: destURL,
            options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                let data = try Data(contentsOf: sourceURL)
                let stagingURL = folderURL.appendingPathComponent(".\(BackupSettings.fileName).tmp")
                try? FileManager.default.removeItem(at: stagingURL)
                try data.write(to: stagingURL, options: .atomic)

                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    _ = try FileManager.default.replaceItemAt(coordinatedURL, withItemAt: stagingURL)
                } else {
                    try FileManager.default.moveItem(at: stagingURL, to: coordinatedURL)
                }
            } catch {
                thrownError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let thrownError { throw thrownError }
    }

    private func recordError(_ error: Error) {
        BackupSettings.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

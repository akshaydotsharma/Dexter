import Foundation
import SwiftData

/// SwiftData container singleton.
///
/// The store backs the iOS local-first data layer (#14). It holds
/// `LocalTodo`, `LocalNote`, `LocalList`, `LocalNoteFolder`, and
/// `LocalKeyword`.
/// SwiftData persists to the app's Application Support directory by default,
/// which survives cache eviction unlike the legacy JSON cache.
///
/// Access the shared `ModelContext` via `SwiftDataStore.shared.context`.
/// Services and view models inject this context; tests can substitute an
/// in-memory container via `SwiftDataStore.makeInMemory()`.
@MainActor
final class SwiftDataStore {
    static let shared = SwiftDataStore()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    private init() {
        do {
            let schema = Schema([
                LocalTodo.self,
                LocalNoteFolder.self,
                LocalNote.self,
                LocalList.self,
                LocalKeyword.self,
            ])
            // SwiftData defaults the store URL to Application Support, but
            // on a fresh simulator that directory doesn't exist yet and
            // CoreData logs a noisy stat failure on first run. Pre-creating
            // the directory and pointing the configuration at an explicit
            // URL avoids both problems.
            let supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let storeURL = supportDir.appendingPathComponent("PersonalDashboard.sqlite")
            let configuration = ModelConfiguration(
                schema: schema,
                url: storeURL
            )
            self.container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to bootstrap SwiftData container: \(error)")
        }
    }

    /// Build an in-memory container for tests or previews.
    static func makeInMemory() -> ModelContainer {
        do {
            let schema = Schema([
                LocalTodo.self,
                LocalNoteFolder.self,
                LocalNote.self,
                LocalList.self,
                LocalKeyword.self,
            ])
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to bootstrap in-memory SwiftData container: \(error)")
        }
    }
}

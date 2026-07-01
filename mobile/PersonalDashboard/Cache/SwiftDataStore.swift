import Foundation
import SwiftData

/// SwiftData container singleton.
///
/// The store backs the iOS local-first data layer (#14). It holds
/// `LocalTodo`, `LocalNote`, `LocalList`, `LocalNoteFolder`, `LocalKeyword`,
/// `LocalTrip`, and `LocalItineraryItem`.
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
                LocalTrip.self,
                LocalItineraryItem.self,
                LocalExpense.self,
                LocalFXRate.self,
                LocalProcessedEmail.self,
                LocalEmailIngestLog.self,
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
        // Runs once at first launch after the UTC-wall-clock change (#168),
        // before any itinerary UI can query. Guarded internally.
        migrateItineraryTimesToUTC()
    }

    /// One-time migration (#168): convert existing itinerary item times from
    /// the old device-local-wall-clock scheme to the new UTC-wall-clock scheme.
    ///
    /// Before #168, `startTime`/`endTime` stored a Date whose DEVICE-local H:M
    /// equalled the stated booking time. After #168 the app displays times with
    /// a UTC-pinned formatter, so those rows would render shifted. This pass
    /// rebuilds each stored Date so its UTC components equal the old device-local
    /// components (i.e. the stated H:M is preserved under the new anchor).
    ///
    /// Assumption: correct when the device timezone now equals the timezone in
    /// effect when the item was created (the common case — items created and
    /// migrated on the same phone in the same zone). Rare items created while
    /// the phone was in a different timezone can be corrected by re-scan (#165)
    /// or a manual edit, both of which re-anchor to UTC wall-clock directly.
    ///
    /// Gated by a `UserDefaults` flag so it runs exactly once. Wrapped in
    /// do/catch — never crashes launch.
    private func migrateItineraryTimesToUTC() {
        let flagKey = "itineraryTimesUTCMigrated_v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flagKey) else { return }

        let ctx = container.mainContext
        let local = Calendar.current
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        // Rebuild `stored` (a device-local wall-clock Date) as a UTC wall-clock
        // Date preserving all components. Returns nil if reconstruction fails.
        func rebased(_ stored: Date) -> Date? {
            let c = local.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: stored
            )
            var out = DateComponents()
            out.year = c.year
            out.month = c.month
            out.day = c.day
            out.hour = c.hour
            out.minute = c.minute
            out.second = c.second
            return utc.date(from: out)
        }

        do {
            let items = try ctx.fetch(FetchDescriptor<LocalItineraryItem>())
            var didChange = false
            for item in items where item.startTime != nil || item.endTime != nil {
                if let start = item.startTime, let r = rebased(start) {
                    item.startTime = r
                    didChange = true
                }
                if let end = item.endTime, let r = rebased(end) {
                    item.endTime = r
                    didChange = true
                }
            }
            if didChange {
                try ctx.save()
            }
            defaults.set(true, forKey: flagKey)
        } catch {
            // Leave the flag unset so a future launch can retry. Never crash.
            NSLog("SwiftDataStore: itinerary UTC time migration failed: %@", String(describing: error))
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
                LocalTrip.self,
                LocalItineraryItem.self,
                LocalExpense.self,
                LocalFXRate.self,
                LocalProcessedEmail.self,
                LocalEmailIngestLog.self,
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

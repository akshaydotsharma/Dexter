import Foundation

extension Notification.Name {
    /// Broadcast after a successful write to the shared SwiftData store from
    /// the AI capture (voice / Shortcut) or chat paths.
    ///
    /// Surfaces backed by manual-fetch view models (Tasks / Notes / Lists)
    /// observe this and re-run their `load()`, since they don't use the
    /// auto-updating `@Query` that keeps Activity / Finance / Itineraries live.
    static let localStoreDidChange = Notification.Name("dev.dexter.localStoreDidChange")
}

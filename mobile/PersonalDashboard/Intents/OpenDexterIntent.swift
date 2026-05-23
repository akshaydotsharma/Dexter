import AppIntents
import Foundation

/// Lightweight App Intent that opens Dexter and routes the user to a
/// specific section / item.
///
/// Why this exists rather than a plain `Link(destination: dexter://...)`
/// inside the Shortcut result snippet:
///   - A snippet `Link` whose URL scheme matches the host app can be
///     auto-fired by iOS Shortcuts when the user taps the system "Done"
///     button, causing Done to open the app instead of dismissing the
///     sheet. Apple's idiomatic snippet-view pattern is `Button(intent:)`,
///     which is treated as a discrete affordance rather than the
///     intent's "implied primary action".
///   - Concentrating the route here means the snippet view doesn't need
///     to know how to construct deep-link URLs.
///
/// The `dexter://` URL scheme is preserved for external callers
/// (Safari paste, share sheet, future notifications) and is still
/// handled in `DexterDeepLink.handle(_:router:)`.
struct OpenDexterIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Dexter"

    static var description = IntentDescription(
        "Opens Dexter and jumps to the relevant section.",
        categoryName: "Navigation"
    )

    /// Forces the app into the foreground when the intent runs.
    /// `perform()` then executes inside the host app's process so we
    /// can mutate the in-app router state directly.
    static var openAppWhenRun: Bool = true

    /// Hidden from the Shortcuts library — this intent exists to back
    /// the snippet button, not as a user-facing shortcut.
    static var isDiscoverable: Bool = false

    /// `AppSection.rawValue` — `tasks`, `notes`, `lists`, `finance`,
    /// `itineraries`, `activity`, etc.
    @Parameter(title: "Section")
    var section: String

    /// Optional UUID string. When present, the destination view will
    /// focus the matching row via `AppRouter.focus`. Empty / nil means
    /// land on the section's index.
    @Parameter(title: "Identifier", default: "")
    var rawIdentifier: String

    init() {}

    init(section: String, id: String?) {
        self.section = section
        self.rawIdentifier = id ?? ""
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let id = rawIdentifier.isEmpty ? nil : UUID(uuidString: rawIdentifier)
        DeepLinkBus.shared.pending = .focus(sectionRaw: section, id: id)
        return .result()
    }
}

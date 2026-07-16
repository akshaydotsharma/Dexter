#if canImport(UIKit)
import UIKit
#endif

/// Lightweight haptic helpers used by row-level destructive actions
/// (swipe-to-delete) so the same feel is reused across surfaces.
///
/// Generators are short-lived intentionally: iOS does not require us to
/// hold onto them for one-shot fires, and creating one per call keeps
/// the call sites local.
///
/// On macOS there is no `UIFeedbackGenerator`; the helpers compile to
/// no-ops so shared call sites (e.g. `SwipeActions`) stay platform-agnostic.
enum Haptics {
    /// A medium-warning thump suitable for a destructive commit
    /// (delete row, drop row). Mirrors the Mail / Reminders feel.
    static func destructive() {
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
        #endif
    }

    /// A short, soft impact for affirmative button presses (e.g. the
    /// itinerary FAB). Re-uses a one-shot `UIImpactFeedbackGenerator` so
    /// the call site can fire-and-forget.
    static func light() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    /// A low-key selection tick used to signal threshold crossings during
    /// continuous drag gestures (e.g. crossing the full-swipe commit
    /// boundary). Quieter than `destructive()` so it doesn't compete with
    /// the warning thump that fires on the actual commit.
    static func tick() {
        #if canImport(UIKit)
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
        #endif
    }
}

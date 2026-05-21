import UIKit

/// Lightweight haptic helpers used by row-level destructive actions
/// (swipe-to-delete) so the same feel is reused across surfaces.
///
/// Generators are short-lived intentionally: iOS does not require us to
/// hold onto them for one-shot fires, and creating one per call keeps
/// the call sites local.
enum Haptics {
    /// A medium-warning thump suitable for a destructive commit
    /// (delete row, drop row). Mirrors the Mail / Reminders feel.
    static func destructive() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    /// A short, soft impact for affirmative button presses (e.g. the
    /// itinerary FAB). Re-uses a one-shot `UIImpactFeedbackGenerator` so
    /// the call site can fire-and-forget.
    static func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }
}

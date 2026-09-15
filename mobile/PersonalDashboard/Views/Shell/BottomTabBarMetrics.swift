import CoreGraphics

/// Layout metrics for the bottom tab bar so surfaces can reserve space
/// above their content (especially sticky-bottom UI like the chat input).
///
/// `height` is the visual footprint occupied above the home-indicator safe
/// area: pill height + the bottom gap between the pill and the safe-area
/// inset. The chat circle's lift above the pill is intentionally NOT
/// included — surfaces reserve space for the pill body, and the lifted
/// circle is allowed to overlap the surface above (it's a floating
/// element, not a strip of chrome).
///
/// Lives in its own UIKit-free file so surfaces that only need the metric
/// (e.g. `TasksView`) can depend on it without dragging in the tab-bar view
/// itself, which is iOS-only chrome (keyboard notifications, haptics).
enum BottomTabBarMetrics {
    /// Total height reserved above the bottom safe area (pill + bottom gap).
    static let height: CGFloat = 74

    /// Bottom inset for a floating "+" FAB. On iOS the FAB clears the floating
    /// tab bar (pill height + a small gap) and is allowed to overlap the
    /// surface above. On macOS there is no tab bar, so the FAB anchors flush to
    /// the true bottom corner with a modest inset (issue #283). Callers keep
    /// their own trailing padding; only the bottom differs per platform.
    static var fabBottomInset: CGFloat {
        #if os(macOS)
        Space.xl
        #else
        height + Space.sm
        #endif
    }

    /// Bottom padding for a surface's own SCROLL CONTENT, so the last thing in a
    /// scroll can be read instead of coming to rest under the floating bar (#559).
    ///
    /// Distinct from `fabBottomInset` because the two answer different questions.
    /// A FAB is positioned AGAINST the bar and is meant to float just clear of
    /// it. Scroll content has to stop ABOVE it, which needs the bar's full height
    /// plus ordinary reading space, not a small gap.
    ///
    /// `Space.xxl` alone is not enough and never was: the bar is 74 pt and `xxl`
    /// is 32, so a card's last line lands underneath it.
    ///
    /// On macOS there is no floating bar at all — the shell is a
    /// `NavigationSplitView` — so this is only a generous bottom margin.
    static var scrollBottomInset: CGFloat {
        #if os(macOS)
        Space.xxl
        #else
        height + Space.lg
        #endif
    }
}

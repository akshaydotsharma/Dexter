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
}

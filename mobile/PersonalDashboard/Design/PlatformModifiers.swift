import SwiftUI

/// Cross-platform shims for SwiftUI text/navigation modifiers that exist only
/// on iOS. Each applies the real modifier on iOS and is a no-op on macOS, so
/// shared views keep one fluent chain instead of `#if` islands mid-builder.
///
/// Added for the native macOS target (issue #281). As more surfaces are
/// ported, route their iOS-only cosmetic modifiers through here.
extension View {
    /// `.textInputAutocapitalization(.never)` on iOS; no-op on macOS
    /// (the modifier is absent from the macOS SwiftUI surface).
    @ViewBuilder
    func noAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// URL keyboard on iOS; no-op on macOS (hardware keyboard, no keyboard type).
    @ViewBuilder
    func urlKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.URL)
        #else
        self
        #endif
    }

    /// Inline nav-bar title on iOS; no-op on macOS, where the title renders in
    /// the window titlebar and there is no display-mode concept.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `.listSectionSpacing(_:)` on iOS; no-op on macOS (the modifier is
    /// unavailable there — macOS Lists space sections differently).
    @ViewBuilder
    func listSectionSpacingCompat(_ spacing: CGFloat) -> some View {
        #if os(iOS)
        self.listSectionSpacing(spacing)
        #else
        self
        #endif
    }
}

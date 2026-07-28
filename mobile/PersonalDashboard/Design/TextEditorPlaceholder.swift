import SwiftUI

// MARK: - TextEditor placeholder alignment
//
// SwiftUI's `TextEditor` has no placeholder, so every multi-line field in the
// app overlays a `Text` in a `ZStack(alignment: .topLeading)`. That only looks
// right if the overlay lands exactly where the editor's FIRST GLYPH will, and
// the glyph is NOT at the editor view's own top-leading corner: the underlying
// platform text view's container insets it.
//
// Getting this wrong is invisible in code review and obvious on screen — the
// caret sits on one line and the placeholder on another (#370, #372). Four call
// sites had each picked their own pair of numbers, so this centralises the
// arithmetic instead.

/// Insets the platform text view behind a `TextEditor` adds around its text.
enum TextEditorMetrics {
    /// `NSTextView`'s per-side `lineFragmentPadding`: how far the first glyph
    /// sits from the text view's leading edge. `NSTextView` adds no vertical
    /// inset, so the glyph is flush with the top.
    static let macGlyphInsetX: CGFloat = 5
}

extension View {
    /// Positions a placeholder overlay on the first glyph of a `TextEditor`,
    /// given the padding applied to that editor.
    ///
    /// Pass the editor's OWN padding, not a pre-adjusted value:
    ///
    /// ```swift
    /// ZStack(alignment: .topLeading) {
    ///     if text.isEmpty {
    ///         Text("Placeholder")
    ///             .textEditorPlaceholderInset(horizontal: Space.md, vertical: Space.sm)
    ///     }
    ///     TextEditor(text: $text)
    ///         .padding(.horizontal, Space.md)
    ///         .padding(.vertical, Space.sm)
    /// }
    /// ```
    ///
    /// - Note: The two platforms genuinely need different numbers, so this is
    ///   not a cosmetic `#if`. `NSTextView` applies a 5pt `lineFragmentPadding`
    ///   per side and no vertical inset. `UITextView` applies horizontal
    ///   padding PLUS its own vertical `textContainerInset`, so the macOS
    ///   arithmetic does not transfer.
    @ViewBuilder
    func textEditorPlaceholderInset(horizontal: CGFloat, vertical: CGFloat) -> some View {
        #if os(macOS)
        // Measured, not assumed: rendering the placeholder in red behind an
        // editor holding the identical string leaves 2 stray antialiasing pixels
        // at this origin, versus 4457 across 30 rows at the values these call
        // sites used before (#372).
        self
            .padding(.leading, horizontal + TextEditorMetrics.macGlyphInsetX)
            .padding(.top, vertical)
        #else
        // iOS keeps the values that were tuned on device, byte for byte. The
        // horizontal `+ 4` is 1pt shy of the 5pt line-fragment padding and the
        // vertical is 12pt past the editor's own inset, which may or may not be
        // right — it has never been measured on an iPhone, and no one has
        // reported it. Deliberately left alone rather than "corrected" by
        // analogy to macOS, since UITextView's vertical inset means the macOS
        // numbers are not the answer here.
        self
            .padding(.horizontal, horizontal + 4)
            .padding(.vertical, vertical + 12)
        #endif
    }
}

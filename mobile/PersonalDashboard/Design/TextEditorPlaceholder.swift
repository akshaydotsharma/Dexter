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

// MARK: - Plain TextField placeholder
//
// `.textFieldStyle(.plain)` costs a `TextField` its placeholder TREATMENT on
// macOS, not just its box (#576). Measured on this machine, Inter-Regular 13
// against white, darkest glyph pixel composited onto the paper:
//
//   plain style, placeholder      black at 0.75 alpha   luminance 0.251
//   default style, placeholder    rgb(146,146,146)      luminance 0.574
//   either style, typed ink       rgb(33,32,39)         luminance 0.134
//
// So a plain field draws its placeholder nearer to ink than to muted, and the
// meal composer read as pre-filled with a breakfast nobody ate. iOS renders the
// same string correctly muted, which is why this is macOS-only.
//
// SwiftUI offers no way to re-tint it. `prompt: Text(…).foregroundColor(…)` was
// measured against the same stack and renders identically to the plain title
// (0.251), so the prompt is not an escape hatch. macOS therefore hands the field
// an EMPTY title and draws the placeholder itself.

/// The two halves of a macOS placeholder, kept together so a call site cannot
/// adopt one and forget the other.
enum PlainFieldPlaceholder {
    /// What to hand `TextField(_:text:axis:)` as its title.
    ///
    /// Empty on macOS, where `plainFieldPlaceholder(_:isVisible:padding:)` draws
    /// the string instead. The real string on iOS, which needs no help.
    static func title(_ text: String) -> String {
        #if os(macOS)
        return ""
        #else
        return text
        #endif
    }

    /// Vertical correction from the field's own padding to the first glyph.
    ///
    /// Measured, not assumed, the same way `macGlyphInsetX` above was: the field
    /// was rendered holding the placeholder as REAL text, the overlay `Text` was
    /// rendered on its own, and the two glyph bounding boxes were differenced.
    /// The horizontal answer came out at exactly the field's padding, so only
    /// the vertical needs a nudge. Stable across 12pt and 16pt padding and
    /// across `lineLimit(2...5)` and `(2...6)`, and unchanged when the field
    /// takes first responder, so the placeholder does not jump on a click.
    ///
    /// Re-measured on iOS for #627 and the answer is the same. Against a focused
    /// three-line composer at 3x, the ink of the drawn placeholder and the ink of
    /// real typed text begin on rows 680 and 681 — a third of a point apart, with
    /// this nudge applied. Hence the rename: it was `macBaselineNudge` while
    /// macOS was the only platform that drew its own placeholder.
    static let baselineNudge: CGFloat = -0.5

    /// What to hand a MULTI-LINE `TextField(_:text:axis:)` as its title.
    ///
    /// Empty on BOTH platforms, unlike `title(_:)`, because the problem on a
    /// multi-line field is position rather than colour (#627).
    ///
    /// UIKit draws a plain field's placeholder vertically CENTRED in the text
    /// container. On a single-line field that is the same place the caret goes,
    /// so nobody notices. Give the field `axis: .vertical` and `lineLimit(3...6)`
    /// and the two part company: the placeholder sits in the middle of a
    /// three-line box while the caret blinks at the top of line one. The field
    /// then reads as though the example text is somewhere the typing will not
    /// go, which is exactly what it means.
    ///
    /// So a multi-line field draws its own placeholder, top-aligned, on both
    /// platforms. iOS gets it for position; macOS already needed it for colour.
    static func multilineTitle(_ text: String) -> String { "" }
}

extension View {
    /// Draws `text` as a muted placeholder over a plain-styled `TextField`.
    ///
    /// Apply it to the field AFTER its own `.padding(…)` and BEFORE its
    /// `.background(…)`, and pass that same padding:
    ///
    /// ```swift
    /// TextField(PlainFieldPlaceholder.title(example), text: $text, axis: .vertical)
    ///     .textFieldStyle(.plain)
    ///     .padding(Space.md)
    ///     .plainFieldPlaceholder(example, isVisible: text.isEmpty, padding: Space.md)
    ///     .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md))
    /// ```
    ///
    /// Order matters both ways. Before the padding the arithmetic has nothing to
    /// work from; after the background the field's own fill would cover the
    /// placeholder.
    ///
    /// - Note: A no-op on iOS, where the field's own title is already drawn in
    ///   the placeholder colour. The call site still passes the real string to
    ///   `PlainFieldPlaceholder.title`, so iOS keeps the native placeholder and
    ///   its behaviour is unchanged.
    @ViewBuilder
    func plainFieldPlaceholder(
        _ text: String,
        isVisible: Bool,
        padding: CGFloat
    ) -> some View {
        #if os(macOS)
        ZStack(alignment: .topLeading) {
            if isVisible {
                Text(text)
                    .font(.edBody)
                    .foregroundStyle(Tokens.mutedSoft)
                    // One line, like AppKit's own placeholder, so a long example
                    // cannot push a two-line field into looking full.
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, padding)
                    .padding(.top, padding + PlainFieldPlaceholder.baselineNudge)
                    .padding(.trailing, padding)
                    // It is paint, not a control: clicks reach the field under
                    // it, and VoiceOver reads the field's own label instead.
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            self
        }
        #else
        self
        #endif
    }
}


extension View {
    /// Draws `text` as a muted placeholder pinned to the FIRST LINE of a
    /// multi-line plain `TextField`, on both platforms (#627).
    ///
    /// The multi-line sibling of `plainFieldPlaceholder(_:isVisible:padding:)`.
    /// That one is a no-op on iOS, because a single-line field's native
    /// placeholder is already drawn muted and in the right place. This one is
    /// never a no-op, because the right place is the thing at issue: see
    /// `PlainFieldPlaceholder.multilineTitle`.
    ///
    /// Apply it to the field AFTER its own padding and BEFORE its background,
    /// and pass the insets that padding used. `trailing` is separate because a
    /// field with controls in its trailing gutter pads asymmetrically, and a
    /// placeholder that ignored that would run under them.
    ///
    /// ```swift
    /// TextField(PlainFieldPlaceholder.multilineTitle(example), text: $text, axis: .vertical)
    ///     .textFieldStyle(.plain)
    ///     .lineLimit(3...6)
    ///     .padding(Space.md)
    ///     .padding(.trailing, gutter)
    ///     .multilinePlainFieldPlaceholder(example, isVisible: text.isEmpty,
    ///                                     leading: Space.md, top: Space.md,
    ///                                     trailing: Space.md + gutter)
    ///     .background(…)
    /// ```
    @ViewBuilder
    func multilinePlainFieldPlaceholder(
        _ text: String,
        isVisible: Bool,
        leading: CGFloat,
        top: CGFloat,
        trailing: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if isVisible {
                Text(text)
                    .font(.edBody)
                    .foregroundStyle(Tokens.mutedSoft)
                    // One line, like both platforms' native placeholders, so a
                    // long example cannot make an empty field look full.
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, leading)
                    .padding(.top, top + PlainFieldPlaceholder.baselineNudge)
                    .padding(.trailing, trailing)
                    // It is paint, not a control: taps reach the field under it,
                    // and VoiceOver reads the field's own label instead.
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            self
        }
    }
}

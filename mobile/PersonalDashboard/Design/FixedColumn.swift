import SwiftUI

extension View {
    /// A value in a fixed-width column: one line, shrunk rather than broken.
    ///
    /// The three parts have to ship together, and #616 is what happens when they
    /// do not. The Finance share column was a bare `frame(width: 30)` around a
    /// `Text`, and `100%` measures 35.1pt in the caption face with
    /// `monospacedDigit()`, so SwiftUI did the only thing left to it and wrapped:
    /// "100" on one line, "%" on the next. `MealBalanceBarRow` carried the same
    /// unguarded shape (#618) and would have reached it from the other end, at
    /// four digits or a larger text size.
    ///
    /// A width is only ever correct for the strings you measured at the default
    /// text size. `lineLimit(1)` is what makes the overflow case a shrink instead
    /// of a break, because `minimumScaleFactor` engages only once wrapping is
    /// disallowed. Binding all three to one call means the next fixed column
    /// cannot be written without its guard.
    ///
    /// This does NOT excuse an under-measured width: shrinking is a backstop for
    /// accessibility sizes, not a substitute for a column that fits its own worst
    /// case. Measure the longest string the column can print, in the real face,
    /// and size to that.
    ///
    /// - Parameters:
    ///   - width: the column width, sized for the longest string it can print.
    ///   - alignment: how the value sits in the column. Numeric columns read
    ///     down their last digit, hence `.trailing` by default.
    ///   - minimumScale: how far the value may shrink before it clips.
    func fixedColumn(
        width: CGFloat,
        alignment: Alignment = .trailing,
        minimumScale: CGFloat = 0.75
    ) -> some View {
        self
            .lineLimit(1)
            .minimumScaleFactor(minimumScale)
            .frame(width: width, alignment: alignment)
    }
}

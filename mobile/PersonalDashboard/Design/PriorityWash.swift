import SwiftUI

// MARK: - Priority wash (issue #376)

/// A glass-like row highlight keyed to a task's priority. Replaces the thin
/// colored rail that used to sit at a task row's leading edge.
///
/// The rail encoded priority as chrome bolted to the row and crowded the
/// completion circle for the leading edge. This washes the hue across the row
/// itself instead: a rounded, very low alpha gradient that starts at the
/// leading edge and settles toward clear, with a hairline of the same hue on
/// the perimeter so the shape has an edge to read against paper.
///
/// The alpha budget is deliberately small. Titles, descriptions, due dates and
/// tag pills all sit on top of this, so the wash has to register as texture at
/// a glance and disappear when you actually read the row. Dark mode carries
/// slightly more alpha: the priority tokens resolve to pastels there, and a
/// pastel over near-black needs more coverage to register at all.
///
/// `.none` gets no wash. Every task would otherwise be tinted and priority
/// would stop being a signal — the same reason Waldo (website-risk) tints only
/// the rows it wants read as elevated rather than every row in the table.
struct PriorityWash: ViewModifier {
    let priority: TaskPriority
    /// Completed rows fade the wash rather than dropping it, so a done P0 is
    /// still identifiable in the Completed section without shouting.
    var dimmed: Bool = false

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background(wash)
    }

    @ViewBuilder
    private var wash: some View {
        if let hue = Tokens.priorityWashHue(for: priority) {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            // Front-loaded on purpose. The tint concentrates
                            // where the rail used to be and has mostly
                            // dissolved by the middle of the row, so a list
                            // where every task carries a priority still reads
                            // as rows of text rather than bands of colour.
                            .init(color: hue.opacity(leadAlpha), location: 0),
                            .init(color: hue.opacity(trailAlpha), location: 0.55),
                            .init(color: hue.opacity(trailAlpha * 0.5), location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                // No border. The hairline gave the wash a defined edge, but it
                // also drew the row as a tile — a bordered box the eye reads
                // before it reads the text. Fill only: the tint has to hold the
                // shape on its own.
                // Held off the row's horizontal edges so the pill floats. On
                // macOS rows run to the pane boundary (#339), and a wash flush
                // against the sidebar seam would read as a second pane rather
                // than as part of the row.
                .padding(.horizontal, RowMetrics.priorityWashInset)
        }
    }

    private var isDark: Bool { scheme == .dark }

    /// Alpha at the leading edge, where the wash is strongest.
    ///
    /// Small numbers on purpose: a real store has a priority on nearly every
    /// task, so this alpha is what the whole list looks like, not what one
    /// highlighted row looks like. Measured on device at 0.17/dark it read as
    /// a colored slab per row; 0.10 reads as a tint.
    private var leadAlpha: Double {
        let base = isDark ? 0.10 : 0.09
        return dimmed ? base * 0.4 : base
    }

    /// Alpha past the midpoint. Not fully clear: the row keeps a whisper of
    /// hue all the way across so a long title doesn't outrun the signal.
    private var trailAlpha: Double {
        let base = isDark ? 0.025 : 0.02
        return dimmed ? base * 0.4 : base
    }

    // No stroke alpha: the wash is fill-only. A perimeter hairline was tried and
    // dropped — it turned the row into a bordered tile.
}

extension View {
    /// Applies the priority wash for `priority` as this view's background.
    /// No-op for `.none`.
    func priorityWash(_ priority: TaskPriority, dimmed: Bool = false) -> some View {
        modifier(PriorityWash(priority: priority, dimmed: dimmed))
    }
}

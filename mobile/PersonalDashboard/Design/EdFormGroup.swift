import SwiftUI

/// The grouped-card grammar of Dexter's editors, lifted out of the Tasks editor
/// (`TaskEditorSheet`) so a second editor can draw the same thing rather than a
/// lookalike (#687 round 6).
///
/// The Tasks editor had these as private helpers, which is why the Planner's
/// sheets grew their own paper-filled fields and system date pills: there was
/// nothing to call. `TaskEditorSheet` now calls these too, so the two editors
/// cannot drift apart.

/// A rounded inset card grouping one or more rows, with a hairline border.
struct EdFormGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }
}

/// Gray eyebrow header above a grouped card (the Reminders section header).
struct EdFormSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .eyebrow()
            .padding(.horizontal, Space.xs)
            .padding(.top, Space.xs)
    }
}

/// Thin inset separator between rows within a grouped card.
struct EdFormRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Tokens.divider)
            .frame(height: 0.5)
            .padding(.leading, Space.md)
    }
}

/// Small coloured rounded tile carrying an SF Symbol: the Reminders row icon.
struct EdIconTile: View {
    let symbol: String
    let color: Color

    init(_ symbol: String, _ color: Color) {
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color)
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

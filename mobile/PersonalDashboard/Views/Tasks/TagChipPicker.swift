import SwiftUI

// MARK: - Wrapping flow layout

/// A minimal flow layout: lays subviews left-to-right and wraps to the next
/// line when the current row runs out of horizontal space. iOS 17+ `Layout`.
/// The app has no other flow/wrap primitive, so this is the reusable one.
struct WrapLayout: Layout {
    var spacing: CGFloat = Space.sm
    var lineSpacing: CGFloat = Space.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height }
            + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = maxWidth.isFinite ? maxWidth : (rows.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.indices.isEmpty
                ? size.width
                : current.width + spacing + size.width
            if !current.indices.isEmpty && projected > maxWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = current.indices.count == 1 ? size.width : current.width + spacing + size.width
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Tag chip picker

/// Single-select tag picker rendered as wrapping capsule chips. A todo carries
/// exactly one tag, so tapping an unselected chip selects it and tapping the
/// selected chip clears the selection. A trailing "New tag" affordance reveals
/// an inline field for creating a tag that isn't in the list yet.
struct TagChipPicker: View {
    /// The selected tag. Empty string means "no tag". Single-select.
    @Binding var selection: String
    /// Existing distinct tags, already sorted by the caller. The picker folds
    /// in the current selection so a brand-new or one-off tag still shows.
    let tags: [String]

    @State private var isAddingNew = false
    @State private var newTagText = ""
    @FocusState private var newTagFocused: Bool

    /// Chips to render: the caller's tags plus the current selection if it's
    /// not already present (covers a freshly-added tag and an edited todo's
    /// sole-owner tag).
    private var displayTags: [String] {
        var result = tags
        let sel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sel.isEmpty && !result.contains(where: { $0.caseInsensitiveCompare(sel) == .orderedSame }) {
            result.append(sel)
        }
        return result
    }

    var body: some View {
        WrapLayout(spacing: Space.sm, lineSpacing: Space.sm) {
            ForEach(displayTags, id: \.self) { tag in
                chip(tag)
            }
            addNewChip
        }
    }

    private func isSelected(_ tag: String) -> Bool {
        selection.caseInsensitiveCompare(tag) == .orderedSame && !selection.isEmpty
    }

    private func chip(_ tag: String) -> some View {
        let selected = isSelected(tag)
        return Button {
            selection = selected ? "" : tag
        } label: {
            Text(tag)
                .font(.edFootnote)
                .foregroundStyle(selected ? Tokens.accentTasks : Tokens.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? Tokens.accentTasks.opacity(0.12) : Tokens.surface)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(selected ? Tokens.accentTasks : Tokens.border,
                                lineWidth: selected ? 1 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var addNewChip: some View {
        if isAddingNew {
            TextField("New tag", text: $newTagText)
                .noAutocapitalization()
                .autocorrectionDisabled(true)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .focused($newTagFocused)
                .submitLabel(.done)
                .onSubmit { commitNewTag() }
                .frame(minWidth: 120, maxWidth: 200)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
        } else {
            Button {
                isAddingNew = true
                DispatchQueue.main.async { newTagFocused = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("New tag")
                        .font(.edFootnote)
                }
                .foregroundStyle(Tokens.muted)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Capsule(style: .continuous).fill(Tokens.surface))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Tokens.border, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add new tag")
        }
    }

    private func commitNewTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { selection = trimmed }
        newTagText = ""
        isAddingNew = false
        newTagFocused = false
    }
}

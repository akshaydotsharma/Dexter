import SwiftUI

#if os(macOS)

/// One task inside a block (#446).
///
/// A nested object: a bordered `surface2` tile inside a `surface` card, the
/// construction this codebase has already established as reading correctly in
/// both themes. It is a real `LocalTodo` — ticking it here is ticking it in
/// Tasks, which is the reason a board tile is not a scribble the board owns.
///
/// macOS-only, and not because of any API it uses. The pointer targets here are
/// sized to AppKit's 24pt comfortable minimum, and the spec's hard constraint
/// for the iOS projection is 44pt on every one of them. Carrying a macOS
/// pointer number onto the phone is exactly the mistake worth compiling out.
struct VisionTileRow: View {
    let todo: Todo
    /// Due text appears at medium and large only. At small there are no tiles
    /// at all, so this is really "the block is wide enough for a second column
    /// of information".
    let showsDue: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var completed: Bool { todo.completed }

    var body: some View {
        HStack(spacing: Space.sm) {
            checkbox
            Text(todo.title)
                .font(.edBody)
                .foregroundStyle(completed ? Tokens.muted : Tokens.ink)
                .strikethrough(completed, color: Tokens.mutedSoft)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Space.xs)
            if showsDue, let due = todo.dueDate {
                Text(Self.shortDue(due))
                    .font(.edCaption)
                    .foregroundStyle(dueColor(for: due))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .frame(minHeight: VisionBlockMetrics.tileHeight)
        // Wash first so it sits directly behind the content, then the solid
        // fill behind that. `compact` because a 156pt tile compresses the
        // gradient's ramp into a third of the distance it was tuned for.
        .priorityWash(todo.taskPriority, dimmed: completed, compact: true)
        .background(completed ? Tokens.paper2 : Tokens.surface2)
        // Clipped to the tile's own 6pt radius: the wash draws itself at
        // `Radius.md`, which is the row radius it was built for, and would
        // otherwise show square-ish corners past the tile's tighter curve.
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .paperBorder(hovering ? Tokens.borderStrong : Tokens.border, radius: Radius.sm)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(completed ? "Completed" : "Not completed")
        .accessibilityAddTraits(.isToggle)
    }

    // MARK: - Checkbox

    /// 14pt glyph in a 26 × 26 target: comfortably past AppKit's 24pt pointer
    /// minimum without making the tile any taller than the glyph needs.
    private var checkbox: some View {
        Button(action: onToggle) {
            Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(completed ? Tokens.success : Tokens.mutedSoft)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)   // the whole tile is the toggle
    }

    // MARK: - Menu

    /// Two destructive-adjacent actions the concept doc requires be told apart.
    ///
    /// AppKit draws menu items, so the separation is carried by what AppKit
    /// honours: the `.destructive` role (which tints Delete red) and a divider
    /// between them. A `foregroundStyle` on a menu label would be ignored, so
    /// there is no point asserting one here.
    @ViewBuilder
    private var menu: some View {
        Button {
            onRemove()
        } label: {
            Label("Remove from board", systemImage: "minus.circle")
        }
        Divider()
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete task", systemImage: "trash")
        }
    }

    // MARK: - Due

    /// Verbatim from `TasksView.dueColor(for:)`, with one addition: a completed
    /// task is not overdue any more, so leaving its date red would be false.
    private func dueColor(for date: Date) -> Color {
        if completed { return Tokens.mutedSoft }
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        if date < now { return Tokens.danger }
        if date < tomorrow { return Tokens.warning }
        return Tokens.inkSoft
    }

    /// Bare text, no capsule. That is the deliberate difference from the block's
    /// urgency chip, which IS a capsule at rungs 3 to 5: two objects, two shapes,
    /// never confused.
    private static func shortDue(_ date: Date) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0

        if days < 0 { return "\(-days)d ago" }
        if days == 0 { return "Today" }
        if days == 1 { return "Tomorrow" }
        if days <= 6 {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }

    /// The wash is decorative; priority's authoritative carrier has always been
    /// the task detail and this label.
    private var accessibilityLabel: String {
        var parts = [todo.title]
        parts.append("Priority \(todo.taskPriority == .none ? "none" : todo.taskPriority.label)")
        if let due = todo.dueDate {
            parts.append("Due \(due.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: ". ")
    }
}

#endif

import SwiftUI

#if os(macOS)

/// One row in a block's list (#446).
///
/// Renders a `VisionRow`, so a borrowed task and the block's own item are the
/// same object here: same tile, same checkbox, same height, same remove button.
/// That sameness is the design. The first pass gave items a distinct shape — a
/// dot and a line of grey text — on the theory that "lives only here" was worth
/// signalling. Reversed in review 2026-08-07: where a row is STORED is not a
/// fact the person ticking it needs at a glance, and the shape it was given cost
/// the one thing a list is for, which is a box to tick.
///
/// What still differs is what the row can DO, and only where the storage forces
/// it. An item's text belongs to the block, so clicking it drops a caret in; a
/// task's title belongs to Tasks, so it does not. Removing an item destroys it,
/// because there is nowhere else it exists; removing a task only takes it off
/// the board. Both are named in the menu rather than inferred.
///
/// A nested object: a bordered `surface2` tile inside a `surface` card, the
/// construction this codebase has already established as reading correctly in
/// both themes.
///
/// macOS-only, and not because of any API it uses. The pointer targets here are
/// sized to AppKit's 24pt comfortable minimum, and the spec's hard constraint
/// for the iOS projection is 44pt on every one of them. Carrying a macOS
/// pointer number onto the phone is exactly the mistake worth compiling out.
struct VisionTileRow: View {
    let row: VisionRow
    /// Due text appears at medium and large only. At small there are no rows at
    /// all, so this is really "the block is wide enough for a second column of
    /// information".
    let showsDue: Bool
    /// True while this row's text is being edited in place. Items only.
    let isEditing: Bool
    let onToggle: () -> Void
    /// Click the title. Nil for a task, whose title is not the board's to change.
    let onBeginEdit: (() -> Void)?
    /// Report the final text. `continuing` is true when Return was pressed, so
    /// the editor knows to open the next item. Items only.
    let onCommit: ((_ text: String, _ continuing: Bool) -> Void)?
    /// Escape. Items only.
    let onCancel: (() -> Void)?
    /// Take a task off the board. Nil for an item, which has no board to leave.
    let onRemoveFromBoard: (() -> Void)?
    /// Destroy the row: the task itself, or the item.
    let onRemove: () -> Void

    @State private var hovering = false
    @State private var draft = ""
    /// Plain `@State`, deliberately NOT `@FocusState`.
    ///
    /// It was `@FocusState`, and that is what made renaming an item take two
    /// clicks. SwiftUI's focus system owns a `@FocusState` value, and nothing
    /// here binds one with `.focused(_:)` — `MacClearTextField` takes a plain
    /// `Binding<Bool>` and drives AppKit's first responder itself. So setting it
    /// true in `onAppear` was reverted by SwiftUI on the same render, the field
    /// mounted unfocused, and because a mounted `NSTextField` looks almost
    /// exactly like the `Text` it replaced, the first click appeared to do
    /// nothing. The second click then focused the field natively, which is why
    /// it always worked on the second try.
    ///
    /// `VisionTileRowFocusTests` is that bug: it hosts this row in a real window
    /// and asserts the caret is in the field. It fails on `@FocusState`.
    @State private var focused = false
    /// Set by Escape, before the field resigns.
    ///
    /// Resigning fires the blur, and the blur is the commit path, so without
    /// this Escape would save the edit it exists to abandon. Lives on the row
    /// rather than in the editor because it is about ONE field's teardown, and
    /// the row is torn down immediately afterwards — nothing outlives it.
    @State private var cancelling = false

    private var completed: Bool { row.completed }

    private var due: Date? {
        if case .task(let todo) = row { return todo.dueDate }
        return nil
    }

    private var priority: TaskPriority {
        if case .task(let todo) = row { return todo.taskPriority }
        return .none
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            checkbox
            title
            Spacer(minLength: Space.xs)
            if showsDue, let due {
                Text(Self.shortDue(due))
                    .font(.edCaption)
                    .foregroundStyle(dueColor(for: due))
                    .lineLimit(1)
            }
            removeButton
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .frame(minHeight: VisionBlockMetrics.tileHeight)
        // Wash first so it sits directly behind the content, then the solid
        // fill behind that. `compact` because a 156pt tile compresses the
        // gradient's ramp into a third of the distance it was tuned for.
        .priorityWash(priority, dimmed: completed, compact: true)
        .background(completed ? Tokens.paper2 : Tokens.surface2)
        // Clipped to the tile's own 6pt radius: the wash draws itself at
        // `Radius.md`, which is the row radius it was built for, and would
        // otherwise show square-ish corners past the tile's tighter curve.
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .paperBorder(hovering ? Tokens.borderStrong : Tokens.border, radius: Radius.sm)
        // The WHOLE tile edits, not just the glyphs of the title.
        //
        // A short item leaves most of its row empty, and clicking that empty
        // space did nothing — which reads as the row being dead rather than as
        // having missed a target. `contentShape` is what makes the transparent
        // padding hittable at all; without it a tap gesture here only fires over
        // drawn content, which is the same small target with extra steps.
        //
        // The checkbox and the remove × keep their clicks: a `Button` inside
        // takes precedence over an ancestor's tap gesture, so the two things the
        // user named ("the redo button", "the cross") still do their own job.
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditing else { return }
            onBeginEdit?()
        }
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

    // MARK: - Title

    @ViewBuilder
    private var title: some View {
        if isEditing, let onCommit {
            MacClearTextField(
                placeholder: "Item",
                text: $draft,
                isFocused: Binding(get: { focused }, set: { focused = $0 }),
                // Return: save this line and open the next one. The editor
                // decides whether there IS a next one — a blank line ends the
                // run — so this only reports which key was pressed.
                onSubmit: { onCommit(draft, true) },
                // Clicking away commits too. A row left in edit because the
                // user's attention moved elsewhere would be lost on the next
                // reload, and losing typed text is never the safer default.
                //
                // This also fires when the field is torn down by a re-render,
                // which is how a row that has ALREADY lost the caret reports its
                // text. `VisionItemEditor` is built for that: the write happens,
                // the focus does not move.
                onFocusChange: { isFocused in
                    guard !isFocused else { return }
                    guard !cancelling else { cancelling = false; return }
                    onCommit(draft, false)
                },
                onCancel: {
                    cancelling = true
                    onCancel?()
                },
                // This field is the item, not a draft row that outlives what it
                // makes. Return hands the line to the editor, which opens a
                // fresh row below and tears this one down; clearing it first
                // meant the teardown reported the item as emptied, and an empty
                // item is a removed one (#453).
                clearsOnSubmit: false,
                placeholderColor: Tokens.mutedSoft
            )
            .onAppear {
                draft = row.title
                focused = true
            }
            .visionPassThrough(cursor: .text)
        } else if let onBeginEdit {
            Text(row.title.isEmpty ? "Item" : row.title)
                .font(.edBody)
                .foregroundStyle(titleColor)
                .strikethrough(completed, color: Tokens.mutedSoft)
                .lineLimit(1)
                .truncationMode(.tail)
                // The tap that starts the edit is on the whole tile, not here.
                // What is left is the I-BEAM, which stays scoped to the text:
                // the pointer layer checks text rects before control rects, so
                // publishing the whole row as text would put an I-beam over the
                // checkbox and the × as well.
                .visionPassThrough(cursor: .text)
        } else {
            Text(row.title)
                .font(.edBody)
                .foregroundStyle(titleColor)
                .strikethrough(completed, color: Tokens.mutedSoft)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var titleColor: Color {
        if completed { return Tokens.muted }
        return row.title.isEmpty ? Tokens.mutedSoft : Tokens.ink
    }

    // MARK: - Remove

    /// Destroy this row, revealed on hover in an always-reserved slot so nothing
    /// shifts.
    ///
    /// Added because the context menu turned out not to count as a way to do
    /// this (#446 follow-up). Right-click worked the whole time, and that is
    /// exactly the problem: an action whose only route is a gesture you have to
    /// already suspect is there reads, to the person using it, as an action that
    /// does not exist.
    ///
    /// On an item this is the only exit, because an item exists nowhere else. On
    /// a task it is the softer of the two — it takes the task off the board and
    /// leaves it alive in Tasks — and the `help` string is load-bearing rather
    /// than decorative, since an unlabelled × next to a task is most naturally
    /// read as the other thing.
    private var removeButton: some View {
        Button(action: onRemoveFromBoard ?? onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Tokens.mutedSoft)
                .frame(width: VisionBlockMetrics.rowActionSlot, height: VisionBlockMetrics.rowActionSlot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0)
        .help(onRemoveFromBoard == nil ? "Remove item" : "Remove from board")
        .accessibilityLabel(
            onRemoveFromBoard == nil ? "Remove \(row.title)" : "Remove \(row.title) from board"
        )
    }

    // MARK: - Menu

    /// AppKit draws menu items, so separation is carried by what AppKit honours:
    /// the `.destructive` role (which tints the item red) and a divider. A
    /// `foregroundStyle` on a menu label would be ignored, so there is no point
    /// asserting one here.
    @ViewBuilder
    private var menu: some View {
        if let onRemoveFromBoard {
            Button {
                onRemoveFromBoard()
            } label: {
                Label("Remove from board", systemImage: "minus.circle")
            }
            Divider()
        }
        Button(role: .destructive, action: onRemove) {
            Label(row.isTask ? "Remove task" : "Remove item", systemImage: "trash")
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
        var parts = [row.title]
        if case .task(let todo) = row {
            parts.append("Priority \(todo.taskPriority == .none ? "none" : todo.taskPriority.label)")
            if let due = todo.dueDate {
                parts.append("Due \(due.formatted(date: .abbreviated, time: .omitted))")
            }
        } else {
            parts.append("Board item")
        }
        return parts.joined(separator: ". ")
    }
}

#endif

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Commands

/// Everything a tile can be asked to do, from its quick view, its context
/// menu, or a double click (#687 round 6, the Google Calendar model).
enum PlannerTileCommand: Equatable {
    /// Open the editor: block details for a Dexter item.
    case edit
    /// Open the read-only details of a calendar event.
    case details
    /// Ask how to delete it (see `PlannerDeletion`).
    case delete
    /// Decline in Dexter. Nil scope: ask when the event repeats.
    case decline(EventOverrideService.Scope?)
    case undoDecline
    /// Remove from the Planner. Nil scope: ask when the event repeats.
    case remove(EventOverrideService.Scope?)
    /// Mark the Dexter task behind the tile complete, or reopen it (#695).
    case toggleComplete
    /// Put an event Dexter shows moved back at its calendar time (#697).
    case resetMove
}

/// One line of a tile's context menu, as data, so the iPhone's SwiftUI menu
/// and the Mac's `NSMenu` are built from one list and the list is testable.
struct PlannerMenuEntry: Equatable {
    var title: String
    var systemImage: String? = nil
    /// Nil for a line that only informs ("Declined in your calendar").
    var command: PlannerTileCommand? = nil
    var children: [PlannerMenuEntry] = []
    var isDestructive = false
    var isDivider = false

    static let divider = PlannerMenuEntry(title: "", isDivider: true)
}

enum PlannerTileMenu {
    /// The menu for a tile. A Dexter item: Edit, then Delete. A calendar
    /// event: Details, then the Dexter-only Decline and Remove (#689), with
    /// "only this one / the whole series" for a repeating event.
    static func entries(for item: PlannerItem, event: PlannerEvent?) -> [PlannerMenuEntry] {
        if item.isFixed {
            guard let ev = event else { return [] }
            var out: [PlannerMenuEntry] = [
                .init(title: "Details…", systemImage: "info.circle", command: .details),
                .divider,
            ]
            switch ev.decline {
            case .atSource:
                out.append(.init(title: "Declined in your calendar"))
            case .inDexter:
                out.append(.init(title: "Undo decline", systemImage: "arrow.uturn.backward", command: .undoDecline))
            case .none:
                out.append(scoped("Decline in Dexter", "xmark.circle", ev) { .decline($0) })
            }
            out.append(scoped("Remove from Planner", "eye.slash", ev) { .remove($0) })
            if ev.isMovedInDexter {
                out.append(.divider)
                out.append(.init(title: "Reset to calendar time", systemImage: "clock.arrow.circlepath", command: .resetMove))
            }
            return out
        }
        var out: [PlannerMenuEntry] = []
        if let complete = completeEntry(for: item) { out.append(complete) }
        out.append(.init(title: "Edit…", systemImage: "pencil", command: .edit))
        if !PlannerDeletion.choices(for: item).isEmpty {
            out.append(.divider)
            out.append(.init(title: "Delete…", systemImage: "trash", command: .delete, isDestructive: true))
        }
        return out
    }

    /// A To-plan row: the task itself, so Mark complete, Edit and Delete.
    static func toPlanEntries(for task: PlannerTask) -> [PlannerMenuEntry] {
        [
            completeEntry(completed: task.completed),
            .init(title: "Edit…", systemImage: "pencil", command: .edit),
            .divider,
            .init(title: "Delete…", systemImage: "trash", command: .delete, isDestructive: true),
        ]
    }

    /// True when a tile stands for a Dexter task, so it can be completed: a
    /// timed or all-day task, or a planned task block. Never a calendar event
    /// or a manual block with no task (#695).
    static func canComplete(_ item: PlannerItem) -> Bool {
        !item.isFixed && !(item.taskUUID ?? "").isEmpty
    }

    /// The menu line, and the quick view button, for a task's completion.
    static func completeEntry(for item: PlannerItem) -> PlannerMenuEntry? {
        canComplete(item) ? completeEntry(completed: item.completed) : nil
    }

    static func completeEntry(completed: Bool) -> PlannerMenuEntry {
        completed
            ? .init(title: "Mark incomplete", systemImage: "arrow.uturn.backward.circle", command: .toggleComplete)
            : .init(title: "Mark complete", systemImage: "checkmark.circle", command: .toggleComplete)
    }

    private static func scoped(_ title: String, _ image: String, _ ev: PlannerEvent,
                               _ make: (EventOverrideService.Scope) -> PlannerTileCommand) -> PlannerMenuEntry {
        if ev.isRecurring {
            return .init(title: title, systemImage: image, children: [
                .init(title: "Only this event", command: make(.occurrence)),
                .init(title: "All events in the series", command: make(.series)),
            ])
        }
        return .init(title: title, systemImage: image, command: make(.occurrence))
    }
}

// MARK: - Environment

/// What a tile needs from the Planner, handed down through the environment so
/// the day column, the week columns and the all-day row all behave the same.
struct PlannerTileActions {
    /// The tile whose quick view is open, if any.
    var quickViewID: String? = nil
    /// The event behind a tile, for the menu and the quick view.
    var event: (PlannerItem) -> PlannerEvent? = { _ in nil }
    var run: (PlannerTileCommand, PlannerItem) -> Void = { _, _ in }
    var dismissQuickView: () -> Void = {}

    func menu(for item: PlannerItem) -> [PlannerMenuEntry] {
        PlannerTileMenu.entries(for: item, event: event(item))
    }
}

private struct PlannerTileActionsKey: EnvironmentKey {
    static let defaultValue: PlannerTileActions? = nil
}

extension EnvironmentValues {
    var plannerTileActions: PlannerTileActions? {
        get { self[PlannerTileActionsKey.self] }
        set { self[PlannerTileActionsKey.self] = newValue }
    }
}

// MARK: - SwiftUI menu

/// The context menu built from entries: touch and hold on the iPhone, right
/// click on the Mac's all-day pills.
struct PlannerTileMenuContent: View {
    let entries: [PlannerMenuEntry]
    let run: (PlannerTileCommand) -> Void

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
            entry(e)
        }
    }

    @ViewBuilder
    private func entry(_ e: PlannerMenuEntry) -> some View {
        if e.isDivider {
            Divider()
        } else if !e.children.isEmpty {
            Menu {
                ForEach(Array(e.children.enumerated()), id: \.offset) { _, c in
                    if let cmd = c.command { Button(c.title) { run(cmd) } }
                }
            } label: {
                label(e)
            }
        } else if let cmd = e.command {
            Button(role: e.isDestructive ? .destructive : nil) { run(cmd) } label: { label(e) }
        } else {
            Text(e.title)
        }
    }

    @ViewBuilder
    private func label(_ e: PlannerMenuEntry) -> some View {
        if let img = e.systemImage { Label(e.title, systemImage: img) } else { Text(e.title) }
    }
}

extension View {
    /// The tile menu from the environment's actions, when there are any.
    @ViewBuilder
    func plannerTileMenu(_ item: PlannerItem, actions: PlannerTileActions?) -> some View {
        if let actions {
            let entries = actions.menu(for: item)
            if entries.isEmpty {
                self
            } else {
                contextMenu { PlannerTileMenuContent(entries: entries) { actions.run($0, item) } }
            }
        } else {
            self
        }
    }
}

// MARK: - Quick view

/// A tile's quick view (#687 round 6), the Google Calendar card: what it is
/// and when, with one-click Edit and Delete. A popover anchored to the tile on
/// the Mac, a bottom card on the iPhone.
struct PlannerQuickView: View {
    let item: PlannerItem
    let event: PlannerEvent?
    let run: (PlannerTileCommand) -> Void
    let onClose: () -> Void
    /// A To-plan task has no day or time on the Planner yet: its row's own
    /// second line replaces "when", and the source line says it is unplanned.
    var whenOverride: String? = nil
    var sourceOverride: String? = nil

    private var canDelete: Bool { !PlannerDeletion.choices(for: item).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: 2) {
                Spacer(minLength: 0)
                if item.isFixed {
                    iconButton("info.circle", "Details", id: "details") { run(.details) }
                    if let ev = event {
                        switch ev.decline {
                        case .none:
                            iconButton("xmark.circle", "Decline in Dexter", id: "decline") { run(.decline(nil)) }
                        case .inDexter:
                            iconButton("arrow.uturn.backward", "Undo decline", id: "undodecline") { run(.undoDecline) }
                        case .atSource:
                            EmptyView()
                        }
                        iconButton("eye.slash", "Remove from Planner", id: "remove") { run(.remove(nil)) }
                    }
                } else {
                    if let complete = PlannerTileMenu.completeEntry(for: item) {
                        iconButton(complete.systemImage ?? "checkmark.circle", complete.title, id: "complete") {
                            run(.toggleComplete)
                        }
                    }
                    iconButton("pencil", "Edit", id: "edit") { run(.edit) }
                    if canDelete {
                        iconButton("trash", "Delete", id: "delete") { run(.delete) }
                    }
                }
                iconButton("xmark", "Close", id: "close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: Space.md) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(PlannerStyle.color(item.source))
                    .frame(width: 14, height: 14)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.edHeading)
                        .foregroundStyle(Tokens.ink)
                        .strikethrough(item.isDeclined || item.completed, color: Tokens.muted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("planner.quick.title")
                    Text(when)
                        .font(.edSubheadline)
                        .foregroundStyle(Tokens.inkSoft)
                    Text(sourceLine)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                    if let ev = event, ev.decline != .none {
                        Text(ev.decline == .atSource ? "You declined this in your calendar" : "Declined in Dexter")
                            .font(.edCaption.weight(.medium))
                            .foregroundStyle(Tokens.danger)
                    }
                    if let ev = event, let from = ev.movedFrom {
                        // #697: moved in Dexter only; the calendar keeps its time.
                        Text("Moved in Dexter · calendar time \(PlannerStyle.range(from, from.addingTimeInterval(ev.end.timeIntervalSince(ev.start))))")
                            .font(.edCaption.weight(.medium))
                            .foregroundStyle(Tokens.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("planner.quick.movednote")
                        Button("Reset to calendar time") { run(.resetMove) }
                            .buttonStyle(.plain)
                            .font(.edCaption.weight(.semibold))
                            .foregroundStyle(Tokens.accentTasks)
                            .padding(.top, 1)
                            .accessibilityIdentifier("planner.quick.resetmove")
                    }
                    if let ev = event, !ev.location.isEmpty {
                        Label(ev.location, systemImage: "mappin.and.ellipse")
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.md)
        #if os(macOS)
        .frame(width: 300)
        .background(Tokens.surface)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("planner.quick")
    }

    private var when: String {
        if let whenOverride { return whenOverride }
        let day = PlannerStyle.weekdayFormatter.string(from: item.start ?? Date())
            + " " + PlannerStyle.dayMonthFormatter.string(from: item.start ?? Date())
        if let s = item.start, let e = item.end { return "\(day) · \(PlannerStyle.range(s, e))" }
        return "\(day) · no time"
    }

    private var sourceLine: String {
        if let sourceOverride { return sourceOverride }
        if let ev = event {
            return "\(ev.source == .work ? "Work" : "Personal") calendar · \(ev.calendarTitle)"
        }
        if item.isBlock {
            return item.taskUUID?.isEmpty == false ? "Planned task · \(PlannerFormat.duration(item.durationMinutes))" : "Dexter block"
        }
        // An All Day task pill has no hour (#695).
        if item.start == nil {
            if item.overdueDays > 0 { return item.overdueDays == 1 ? "Task · 1 day overdue" : "Task · \(item.overdueDays) days overdue" }
            return "Task · due today, no time"
        }
        return "Task due at this time"
    }

    private func iconButton(_ symbol: String, _ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tokens.inkSoft)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("planner.quick.\(id)")
    }
}

// MARK: - Move handlers

/// What a tile reports while its body is dragged to a new time (#697): the
/// distance in points, downward positive. The caller snaps it with
/// `PlannerDragGeometry.movedStart`.
struct PlannerTileMoveHandlers {
    var onBegin: () -> Void
    var onChange: (CGFloat) -> Void
    var onCommit: (CGFloat) -> Void
    var onPointerBegin: ((CGPoint, AnyObject?) -> Void)? = nil
    var onPointerChange: ((CGPoint, AnyObject?) -> Void)? = nil
    var onPointerCommit: ((CGPoint, AnyObject?) -> Void)? = nil
    var onCancel: (() -> Void)? = nil
}

// MARK: - Mac click handling

#if os(macOS)
/// Sits over a Mac tile and reads the click COUNT from AppKit (#687 round 6).
///
/// Stacked `onTapGesture(count: 2)` / `onTapGesture` makes a single click wait
/// for the double-click interval and is not reachable from a test. Here a
/// click-count-1 release calls `onClick` at once and a count-2 release calls
/// `onDoubleClick`. Since #695 the Planner wires BOTH to the quick view: the
/// first click on any item shows its options, and a double click lands on the
/// same card instead of skipping to the editor. Edit is one click away in it.
/// `acceptsFirstMouse` makes the first click count even when the window is
/// not key. The quick view is an `.applicationDefined` popover that never
/// closes on a click on its own anchor, so the second click arrives here.
///
/// A drag on the body MOVES the tile (#697), when the tile can move: a press
/// that travels `PlannerDragGeometry.dragThreshold` points or more is a move
/// and never a click. The distance is measured in WINDOW space, because the
/// tile (and this view) follows the pointer while it is dragged; measured in
/// this view's own space the distance would feed back into itself, the
/// #687 round 5 resize flicker.
final class PlannerTileClickView: NSView {
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    /// The right-click menu, built fresh on each right click.
    var menuEntries: () -> [PlannerMenuEntry] = { [] }
    var onCommand: (PlannerTileCommand) -> Void = { _ in }
    var label = ""
    /// Nil: the tile does not move, and a drag does nothing.
    var move: PlannerTileMoveHandlers?

    /// Where the press went down, in window space.
    private(set) var anchor: CGPoint?
    private(set) var isMoving = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The drag distance, downward positive. A window's y grows upward;
    /// without a window (headless tests) the point is already in this flipped
    /// view's space, where y grows down. The same rule as the resize strip.
    func dragDistance(from anchor: CGPoint, to event: NSEvent) -> CGFloat {
        window != nil ? anchor.y - event.locationInWindow.y : event.locationInWindow.y - anchor.y
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        anchor = event.locationInWindow
        isMoving = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor, let move else { return }
        if !isMoving {
            guard PlannerDragGeometry.isDrag(from: anchor, to: event.locationInWindow) else { return }
            isMoving = true
            NSCursor.closedHand.push()
            move.onBegin()
            move.onPointerBegin?(anchor, window)
        }
        if let change = move.onPointerChange { change(event.locationInWindow, window) }
        else { move.onChange(dragDistance(from: anchor, to: event)) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = anchor else { return }
        anchor = nil
        if isMoving {
            isMoving = false
            NSCursor.pop()
            if let move {
                if let commit = move.onPointerCommit { commit(event.locationInWindow, window) }
                else { move.onCommit(dragDistance(from: start, to: event)) }
            }
            return
        }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if event.clickCount >= 2 { onDoubleClick() } else { onClick() }
    }

    override func cancelOperation(_ sender: Any?) {
        guard isMoving else { return }
        isMoving = false
        anchor = nil
        NSCursor.pop()
        move?.onCancel?()
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        if move != nil { addCursorRect(bounds, cursor: .openHand) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let entries = menuEntries()
        guard !entries.isEmpty else { return nil }
        return PlannerNSMenu.build(entries, run: onCommand)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

/// Builds an `NSMenu` from menu entries. Each item keeps its own target alive.
enum PlannerNSMenu {
    final class Target: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire(_ sender: Any?) { run() }
    }

    static func build(_ entries: [PlannerMenuEntry], run: @escaping (PlannerTileCommand) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for e in entries {
            if e.isDivider { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: e.title, action: nil, keyEquivalent: "")
            if let img = e.systemImage { item.image = NSImage(systemSymbolName: img, accessibilityDescription: nil) }
            if !e.children.isEmpty {
                item.submenu = build(e.children, run: run)
            } else if let cmd = e.command {
                let target = Target { run(cmd) }
                item.target = target
                item.action = #selector(Target.fire(_:))
                item.representedObject = target
            } else {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
        return menu
    }
}

extension View {
    /// One Mac model for every Planner item (#695): grid tiles, All Day pills
    /// and the week view's all-day tiles. Any click, single or double, opens
    /// the item's quick view anchored to it; right click gives its menu.
    func plannerMacClickTarget(_ item: PlannerItem, actions: PlannerTileActions?,
                               preferredEdge: NSRectEdge = .maxX,
                               move: PlannerTileMoveHandlers? = nil,
                               onClick: @escaping () -> Void) -> some View {
        self
            .overlay {
                PlannerTileClickLayer(
                    label: item.title,
                    onClick: onClick,
                    onDoubleClick: onClick,
                    menuEntries: { actions?.menu(for: item) ?? [] },
                    onCommand: { actions?.run($0, item) },
                    move: move
                )
            }
            .macAnchoredPopover(
                isPresented: Binding(
                    get: { actions?.quickViewID == item.id },
                    set: { shown in if !shown, actions?.quickViewID == item.id { actions?.dismissQuickView() } }
                ),
                // The Planner owns dismissal: a click outside closes it, a click
                // on the item itself does not, so a double click reaches it.
                behavior: .applicationDefined,
                preferredEdge: preferredEdge
            ) {
                PlannerQuickView(
                    item: item,
                    event: actions?.event(item),
                    run: { actions?.run($0, item) },
                    onClose: { actions?.dismissQuickView() }
                )
            }
    }
}

struct PlannerTileClickLayer: NSViewRepresentable {
    let label: String
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    let menuEntries: () -> [PlannerMenuEntry]
    let onCommand: (PlannerTileCommand) -> Void
    var move: PlannerTileMoveHandlers? = nil

    func makeNSView(context: Context) -> PlannerTileClickView {
        let v = PlannerTileClickView()
        update(v)
        return v
    }
    func updateNSView(_ v: PlannerTileClickView, context: Context) { update(v) }
    private func update(_ v: PlannerTileClickView) {
        v.label = label
        v.onClick = onClick
        v.onDoubleClick = onDoubleClick
        v.menuEntries = menuEntries
        v.onCommand = onCommand
        let hadMove = v.move != nil
        v.move = move
        if hadMove != (move != nil) { v.window?.invalidateCursorRects(for: v) }
        v.setAccessibilityIdentifier("planner.tile.\(label)")
    }
}
#endif

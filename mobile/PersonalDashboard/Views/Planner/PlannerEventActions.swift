import SwiftUI

/// Hide and decline for calendar events (#689), handed to every tile through
/// the environment so the grid, the week columns and the all-day row offer the
/// same menu without each view threading closures.
struct PlannerEventActions {
    /// The (already overridden) event behind a tile, if the tile is an event.
    var event: (PlannerItem) -> PlannerEvent? = { _ in nil }
    var decline: (PlannerEvent, EventOverrideService.Scope) -> Void = { _, _ in }
    var undoDecline: (PlannerEvent) -> Void = { _ in }
    var remove: (PlannerEvent, EventOverrideService.Scope) -> Void = { _, _ in }
    var details: (PlannerItem) -> Void = { _ in }
}

private struct PlannerEventActionsKey: EnvironmentKey {
    static let defaultValue: PlannerEventActions? = nil
}

extension EnvironmentValues {
    var plannerEventActions: PlannerEventActions? {
        get { self[PlannerEventActionsKey.self] }
        set { self[PlannerEventActionsKey.self] = newValue }
    }
}

/// The context menu on an event tile: right click on the Mac, touch and hold
/// on the iPhone. Tiles sit above the empty grid, so this never competes with
/// the hold that creates a block.
struct PlannerEventMenu: View {
    let item: PlannerItem
    let actions: PlannerEventActions

    var body: some View {
        if let ev = actions.event(item) {
            Button("Details…") { actions.details(item) }
            Divider()
            switch ev.decline {
            case .atSource:
                Text("Declined in your calendar")
            case .inDexter:
                Button("Undo decline") { actions.undoDecline(ev) }
            case .none:
                scoped("Decline in Dexter", systemImage: "xmark.circle", event: ev) { actions.decline(ev, $0) }
            }
            scoped("Remove from Planner", systemImage: "eye.slash", event: ev) { actions.remove(ev, $0) }
        }
    }

    @ViewBuilder
    private func scoped(_ title: String, systemImage: String, event: PlannerEvent, run: @escaping (EventOverrideService.Scope) -> Void) -> some View {
        if event.isRecurring {
            Menu {
                Button("Only this event") { run(.occurrence) }
                Button("All events in the series") { run(.series) }
            } label: {
                Label(title, systemImage: systemImage)
            }
        } else {
            Button { run(.occurrence) } label: { Label(title, systemImage: systemImage) }
        }
    }
}

extension View {
    /// Adds the event menu to a tile when the tile is a calendar event.
    @ViewBuilder
    func plannerEventMenu(_ item: PlannerItem, actions: PlannerEventActions?) -> some View {
        if let actions, item.isFixed {
            contextMenu { PlannerEventMenu(item: item, actions: actions) }
        } else {
            self
        }
    }
}

// MARK: - Undo toast

struct PlannerToast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    /// The override the Undo button soft-deletes.
    let overrideID: String

    static func == (a: PlannerToast, b: PlannerToast) -> Bool { a.id == b.id }
}

struct PlannerToastView: View {
    let toast: PlannerToast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.edFootnote)
                .foregroundStyle(Tokens.paper)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Undo", action: onUndo)
                .buttonStyle(.plain)
                .font(.edFootnoteStrong)
                .foregroundStyle(Tokens.paper)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(Capsule().stroke(Tokens.paper.opacity(0.6), lineWidth: 1))
                .accessibilityIdentifier("planner.toast.undo")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Tokens.ink, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .shadowLg()
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
    }
}

#if os(macOS)
import SwiftUI
import AppKit

/// A pull-down menu the caller owns, rather than SwiftUI's `Menu` (#446).
///
/// ### Why not `Menu`
///
/// SwiftUI's `Menu` presents an `NSMenu` and tells nobody. Three things on the
/// vision board depend on knowing:
///
/// 1. **The control that opened it has to stay visible.** A block's ellipsis is
///    revealed on hover, and the pointer leaves the card the instant the menu
///    takes the mouse — so clicking the ellipsis made the ellipsis disappear,
///    leaving a menu floating with nothing to say where it came from. Reported
///    as *"the three dots disappear when I click on it"*.
/// 2. **A menu action must not run inside the menu's own tracking loop.**
///    "Attach existing task…" opens an `NSPopover`, and a popover shown while
///    the menu is still dismissing is torn down with it: it appeared, vanished,
///    and came back on the next mouse move when a re-render found the binding
///    still true. Reported as *"the popover shows and then hides and when I move
///    my mouse the popover comes back"*. Here the chosen action runs AFTER
///    `popUp` returns, which is after the menu is off screen.
/// 3. **The board's hover has to freeze for the menu's lifetime**, which needs a
///    begin and an end. That is what `onTrackingChange` is for.
///
/// The menu is built fresh on every press from `entries()`, so checkmarks and
/// titles reflect the state at the moment it opens rather than at the last
/// render.
struct MacMenuButton<Label: View>: View {
    /// Built on press, not at render. Anything derived from live state — a
    /// checkmark, a count — is therefore current.
    let entries: () -> [MacMenuEntry]
    /// True the moment before the menu goes up, false the moment after it comes
    /// down. Called before the chosen action runs, so a handler can clear other
    /// transient chrome without racing whatever the item does.
    var onTrackingChange: (Bool) -> Void = { _ in }
    @ViewBuilder var label: () -> Label

    /// Holds the `NSView` the menu is positioned against. A box rather than
    /// `@State` on the view itself, because it is written from `makeNSView` and
    /// only ever read from an action.
    @State private var anchor = MacMenuAnchor()

    var body: some View {
        Button(action: present) { label() }
            .buttonStyle(.plain)
            .background(MacMenuAnchorView(anchor: anchor))
    }

    private func present() {
        onTrackingChange(true)
        // One turn of the run loop before the menu goes up, so SwiftUI can
        // render what the line above just changed: the ellipsis stays on screen
        // and any popover it opened earlier is gone. `popUp` runs its own event
        // loop, and nothing renders between the call and its return — so a state
        // change made immediately before it would not reach the screen until the
        // menu had already closed.
        DispatchQueue.main.async { MainActor.assumeIsolated(showMenu) }
    }

    /// Everything from here down happens with the menu's own event loop running.
    private func showMenu() {
        guard let view = anchor.view else {
            onTrackingChange(false)
            return
        }

        let target = MacMenuTarget()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries() {
            menu.addItem(entry.makeItem(target: target))
        }

        // Below the button, left edges aligned, with the same 4pt gap AppKit
        // gives a pull-down. `popUp` places the menu's top-left at this point,
        // so which corner of the button that is depends on the view's geometry.
        let below = view.isFlipped
            ? NSPoint(x: 0, y: view.bounds.maxY + 4)
            : NSPoint(x: 0, y: view.bounds.minY - 4)
        // Synchronous: this returns only once the menu has been dismissed.
        menu.popUp(positioning: nil, at: below, in: view)
        onTrackingChange(false)

        // Deliberately after the menu is gone. See (2) above.
        target.chosen?()
    }
}

/// One entry in a `MacMenuButton`'s menu.
enum MacMenuEntry {
    /// A macOS 14 section header: a small grey title, not selectable. Groups
    /// mutually exclusive items without spending a submenu on them.
    case header(String)
    case separator
    case item(
        title: String,
        systemImage: String? = nil,
        isOn: Bool = false,
        action: () -> Void
    )

    @MainActor
    func makeItem(target: MacMenuTarget) -> NSMenuItem {
        switch self {
        case let .header(title):
            return NSMenuItem.sectionHeader(title: title)
        case .separator:
            return .separator()
        case let .item(title, systemImage, isOn, action):
            let item = NSMenuItem(title: title, action: #selector(MacMenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = MacMenuAction(action)
            item.state = isOn ? .on : .off
            if let systemImage {
                item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
            }
            return item
        }
    }
}

/// Remembers which item was picked without running it.
///
/// `NSMenu` sends the action inside its own tracking loop; everything this app
/// does from a menu wants the menu gone first, so the closure is parked here and
/// the caller runs it once `popUp` has returned.
final class MacMenuTarget: NSObject {
    private(set) var chosen: (() -> Void)?

    @objc func pick(_ sender: NSMenuItem) {
        chosen = (sender.representedObject as? MacMenuAction)?.run
    }
}

/// A closure `NSMenuItem.representedObject` can hold.
private final class MacMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// The `NSView` a `MacMenuButton` positions its menu against.
@MainActor
private final class MacMenuAnchor {
    weak var view: NSView?
}

private struct MacMenuAnchorView: NSViewRepresentable {
    let anchor: MacMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
#endif

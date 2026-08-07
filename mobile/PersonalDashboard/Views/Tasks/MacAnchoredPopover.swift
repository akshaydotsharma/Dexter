#if os(macOS)
import SwiftUI
import AppKit

/// A macOS popover that SURVIVES the system file panel (#416).
///
/// SwiftUI's `.popover` creates an `NSPopover` with `.transient` behaviour, and a
/// transient popover closes the instant another window takes key — which
/// `NSOpenPanel` does immediately. Measured all three ways:
///
/// | behaviour           | still shown once the panel is up |
/// |---------------------|----------------------------------|
/// | `.transient`        | no                               |
/// | `.semitransient`    | yes                              |
/// | `.applicationDefined` | yes                            |
///
/// `interactiveDismissDisabled` does not help, because a key-window change is not
/// an interactive dismissal. The only way to keep a popover open across Finder is
/// to own the `NSPopover` and set its behaviour, which is what this does.
///
/// That matters for more than tidiness. The task editor IS the popover, so when it
/// died the read carried on against a destroyed view: no spinner, no parsed values
/// filled in, no card. Keeping it alive is what lets one surface carry the whole
/// operation — press Add, choose a file, watch it parse, see the card, edit it.
///
/// ## Behaviour switching
///
/// `.semitransient` by default, which closes the popover when you interact with the
/// window behind it (the Reminders feel this editor already had) while ignoring
/// other windows taking key. While `isBusy` it becomes `.applicationDefined`, which
/// closes only when we say so, because a stray click in the list should not bin a
/// read that is already running.
struct MacAnchoredPopover<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    /// True while a file panel is open or a read is in flight.
    var isBusy: Bool = false
    /// Who decides when this closes.
    ///
    /// `.semitransient` by default: AppKit closes it when you interact with the
    /// window behind it, which is the Reminders feel the task editor wants.
    ///
    /// `.applicationDefined` hands the whole policy to the caller. The vision
    /// board needs that, because AppKit's policy and the board's pointer
    /// handling disagree about what an interaction is. The board's canvas is one
    /// `NSView` that answers every click and tracks every move, and with a
    /// semitransient popover up, MOVING THE CURSOR dismissed it — the popover
    /// went away while the user was travelling toward it. That was measured, not
    /// guessed: with no key window (an agent-launched app can never get one) the
    /// popover survives re-renders, hover changes, selection changes, cursor
    /// changes, store reloads and posted mouse-moved events, so the dismissal is
    /// coming from AppKit's own monitor in a key window, where it cannot be
    /// observed or overridden — only declined.
    ///
    /// Declining it is safe HERE and only here, because the board already owns
    /// the outside click: `VisionPointerView.mouseDown` clears
    /// `VisionInteraction.popover` for any click it claims and leaves it alone
    /// over a pass-through control. That rule is unit tested; AppKit's was not
    /// even inspectable.
    var behavior: NSPopover.Behavior = .semitransient
    var preferredEdge: NSRectEdge = .minX
    @ViewBuilder var content: () -> PopoverContent

    func makeNSView(context: Context) -> NSView {
        // A zero-size anchor placed by the caller's `.background`, so the popover
        // points at whatever it is attached to.
        let view = NSView(frame: .zero)
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(
            content: content(), isPresented: isPresented, isBusy: isBusy, behavior: behavior
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    /// A hosting controller whose view answers the first click instead of
    /// spending it on becoming key.
    ///
    /// An `NSView` returns `false` from `acceptsFirstMouse` by default, so a
    /// click into a window that is not key is consumed activating it and the
    /// control under the pointer never hears about it. In a popover that reads
    /// as the thing being broken: you click a row, nothing happens, and the
    /// popover is still sitting there — which is exactly how the Vision Board's
    /// attach-task list behaved (#446 follow-up).
    ///
    /// Safe to apply to every popover this modifier hosts. Accepting first mouse
    /// only ever means a click does what it looks like it does; nothing here is
    /// destructive enough to want an activating click swallowed as protection.
    private final class FirstMouseHostingController<Content: View>: NSViewController {
        private final class FirstMouseHostingView<V: View>: NSHostingView<V> {
            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        }

        private let hostingView: FirstMouseHostingView<Content>

        /// Reads and writes the hosted view directly, so updating this still
        /// re-renders the popover while it is open — the reason the caller keeps
        /// a reference to the controller at all.
        var rootView: Content {
            get { hostingView.rootView }
            set { hostingView.rootView = newValue }
        }

        init(rootView: Content) {
            hostingView = FirstMouseHostingView(rootView: rootView)
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

        override func loadView() { view = hostingView }
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: MacAnchoredPopover
        weak var anchor: NSView?
        private let popover = NSPopover()
        private var hosting: FirstMouseHostingController<PopoverContent>?

        init(parent: MacAnchoredPopover) {
            self.parent = parent
            super.init()
            popover.delegate = self
            popover.animates = true
        }

        /// `@MainActor` because the hosting controller is, and this is only ever
        /// reached from `updateNSView`, which is main-actor isolated already.
        @MainActor
        func update(
            content: PopoverContent,
            isPresented: Bool,
            isBusy: Bool,
            behavior: NSPopover.Behavior
        ) {
            // Keep the hosted content in step so the editor re-renders while open.
            if let hosting {
                hosting.rootView = content
            } else {
                let controller = FirstMouseHostingController(rootView: content)
                hosting = controller
                popover.contentViewController = controller
            }
            // Sized from the content, which the editor fixes at 360x520.
            popover.contentSize = hosting?.view.fittingSize ?? NSSize(width: 360, height: 520)
            popover.behavior = isBusy ? .applicationDefined : behavior

            guard let anchor, let window = anchor.window else { return }
            if isPresented, !popover.isShown {
                // Positioned against the WINDOW's content view, at the anchor's rect,
                // rather than against the anchor itself.
                //
                // An NSPopover closes itself when its positioning view leaves the
                // window, and this anchor lives inside a List row: attaching a file
                // reloads the list, the row is rebuilt, and at a date rollover it moves
                // to another section outright. Anchoring to the row therefore meant the
                // popover vanished at the exact moment the read finished — the one
                // moment it exists to show something. The content view outlives all of
                // that, and the popover keeps the screen position it opened at.
                guard let host = window.contentView else { return }
                let rect = anchor.convert(anchor.bounds, to: host)
                popover.show(relativeTo: rect, of: host, preferredEdge: parent.preferredEdge)
            } else if !isPresented, popover.isShown {
                popover.performClose(nil)
            }
        }

        /// Closed by the system (a click behind it while semitransient, or Escape),
        /// so tell the binding rather than letting the two drift apart — a stale
        /// `true` would stop the next click from reopening it.
        ///
        /// `willClose`, not `didClose`. `didClose` fires after the close ANIMATION,
        /// which leaves a window several frames wide in which the binding still
        /// reads `true` while `popover.isShown` is already false. Any re-render
        /// landing in that window hits the `isPresented, !popover.isShown` arm of
        /// `update` and puts the popover straight back up — which is a popover that
        /// cannot be dismissed, and on a surface that re-renders on every mouse
        /// move (the vision board) it is the common case rather than the rare one.
        func popoverWillClose(_ notification: Notification) {
            if parent.isPresented { parent.isPresented = false }
        }
    }
}

extension View {
    /// Attach a popover that survives the file panel. See `MacAnchoredPopover`.
    func macAnchoredPopover<Content: View>(
        isPresented: Binding<Bool>,
        isBusy: Bool = false,
        behavior: NSPopover.Behavior = .semitransient,
        preferredEdge: NSRectEdge = .minX,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background(
            MacAnchoredPopover(
                isPresented: isPresented,
                isBusy: isBusy,
                behavior: behavior,
                preferredEdge: preferredEdge,
                content: content
            )
        )
    }
}
#endif

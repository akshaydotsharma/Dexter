import SwiftUI

#if os(macOS)
import AppKit

/// A scripted pointer gesture, posted into this process's own event queue.
/// Off unless `DEXTER_VISION_SELFTEST` is set.
///
/// This exists because the board's two gestures cannot be verified any other
/// way. A build proves nothing about a gesture lifecycle, a screenshot cannot
/// tell "the drag ended" from "the drag is wedged and the block happens to be
/// in the right place", and `CGEvent.post` needs the app frontmost with its
/// window on the active Space — which on a machine that is mid-presentation, or
/// running headless, it is not. Paired with `VisionProbe`, this makes the drag
/// assertable from a script.
///
/// Spec: `x0,y0,x1,y1[,steps]` in window points, top-left origin.
/// Env: `DEXTER_VISION_SELFTEST_FOCUS=1` to take and hand back the front,
/// `DEXTER_VISION_SELFTEST_RESIZE=1` to drive the grip instead of the body.
///
/// ### Two things this cost a round each to learn
///
/// **The window has to be key.** An app that is not active gets an activation
/// click, not a drag, and no amount of `postEvent` changes that. An external
/// `NSRunningApplication.activate` is not enough when another app holds the
/// front; asking from inside the process is.
///
/// **The whole gesture has to be enqueued before the mouse goes down.** AppKit
/// enters an event-tracking loop on `mouseDown` and pulls from the queue itself,
/// which starves the main-actor continuations this would otherwise use to space
/// the events out. Posting one, awaiting, posting the next delivers exactly one
/// drag event and then stops. Posting the entire sequence up front, with
/// increasing timestamps, lets the tracking loop drain it in order.
///
/// ### The caveat that matters when reading a result
///
/// A burst (`gap = 0`, the default) is drained inside ONE tracking loop, and
/// SwiftUI does not re-render until it exits: every `onChanged` fires before the
/// first body evaluation. So a burst proves the gesture's arithmetic and its
/// commit, and proves nothing at all about anything that depends on a re-render
/// landing mid-gesture — which is exactly the class the #446 wedge belongs to.
/// A passing burst is not evidence that a mid-gesture view update is harmless.
///
/// `DEXTER_VISION_SELFTEST_GAP=<ms>` spaces the events out and does let a
/// re-render land between them, but it has its own artefact: once the queue
/// empties the tracking loop exits, and everything posted afterwards is
/// orphaned, which looks identical to a torn-down gesture. Treat a gapped run as
/// a test of the RECOVERY path (does the session still end?) rather than of the
/// gesture itself.
enum VisionSelfTest {
    static func runIfRequested() async {
        guard let spec = ProcessInfo.processInfo.environment["DEXTER_VISION_SELFTEST"] else { return }
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count >= 4 else {
            VisionProbe.line("selftest.bad-spec \(spec)")
            return
        }
        // Let the board finish its first layout before pretending to touch it.
        try? await Task.sleep(for: .seconds(2))

        guard let window = NSApp.windows.first(where: { !$0.title.isEmpty && $0.frame.width > 400 }) else {
            VisionProbe.line("selftest.no-window")
            return
        }
        window.acceptsMouseMovedEvents = true

        let takeFocus = ProcessInfo.processInfo.environment["DEXTER_VISION_SELFTEST_FOCUS"] != nil
        if takeFocus {
            // Activation does not always take on the first ask when another app
            // is holding the front, so keep asking rather than driving a gesture
            // into a window that will only treat it as an activation click.
            for _ in 1...10 where !window.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
        VisionProbe.line("selftest.key=\(window.isKeyWindow) active=\(NSApp.isActive)")
        guard !takeFocus || window.isKeyWindow else {
            VisionProbe.line("selftest.abort-not-key")
            return
        }

        let height = window.frame.height
        let steps = parts.count > 4 ? Int(parts[4]) : 12
        let from = CGPoint(x: parts[0], y: parts[1])
        let to = CGPoint(x: parts[2], y: parts[3])

        // Window points (top-left) to global screen points (top-left), by
        // arithmetic on the window's own frame — no WindowServer query.
        let flipRef = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
        func screenPoint(for point: CGPoint) -> CGPoint {
            let appKitY = window.frame.origin.y + (height - point.y)
            return CGPoint(x: window.frame.origin.x + point.x, y: flipRef - appKitY)
        }

        var clock = ProcessInfo.processInfo.systemUptime
        var serial = 1
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            // AppKit window space is bottom-left origin; the caller thinks in
            // the same top-left points a screenshot is measured in.
            clock += 0.02
            serial += 1
            return NSEvent.mouseEvent(
                with: type,
                location: NSPoint(x: point.x, y: height - point.y),
                modifierFlags: [],
                timestamp: clock,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: serial,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            )
        }

        var queue: [NSEvent] = []
        func enqueue(_ type: NSEvent.EventType, _ point: CGPoint) {
            if let e = event(type, point) { queue.append(e) } else { VisionProbe.line("selftest.event-nil") }
        }

        // The hover goes first and ALONE, with a real pause after it. Some of
        // what a pointer can grab on this board is hover-revealed — the resize
        // grip is `opacity 0` until the card is hovered — and nothing in the
        // burst below yields to the render loop, so a move bundled with the
        // press would press before the grip existed to be pressed.
        //
        // And a posted `.mouseMoved` is not enough on its own: SwiftUI's
        // `onHover` is backed by an `NSTrackingArea`, which follows the REAL
        // cursor rather than the event stream. So warp the cursor as well. That
        // is the one thing here that touches the machine outside this process,
        // which is why it rides on the same opt-in as taking the front, and why
        // the cursor is put back at the end.
        let cursorBefore = CGPoint(x: NSEvent.mouseLocation.x, y: flipRef - NSEvent.mouseLocation.y)
        if takeFocus { CGWarpMouseCursorPosition(screenPoint(for: from)) }
        if let move = event(.mouseMoved, from) { NSApp.postEvent(move, atStart: false) }
        try? await Task.sleep(for: .milliseconds(600))

        enqueue(.leftMouseDown, from)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            enqueue(.leftMouseDragged, CGPoint(
                x: from.x + (to.x - from.x) * t,
                y: from.y + (to.y - from.y) * t
            ))
        }
        enqueue(.leftMouseUp, to)

        let gapMS = Int(ProcessInfo.processInfo.environment["DEXTER_VISION_SELFTEST_GAP"] ?? "") ?? 0
        VisionProbe.line("selftest.start \(Int(from.x)),\(Int(from.y)) -> \(Int(to.x)),\(Int(to.y)) events=\(queue.count) gap=\(gapMS)ms")

        if gapMS <= 0 {
            for e in queue { NSApp.postEvent(e, atStart: false) }
        } else {
            // A timer in `.common` mode, NOT `Task.sleep` and NOT
            // `DispatchQueue.main.asyncAfter`: both of those are starved by the
            // event-tracking loop AppKit enters on mouse-down, which is the
            // whole reason the naive version delivered exactly one drag event.
            // `.common` includes `.eventTracking`, so this keeps firing inside
            // it — and spacing the events out is what lets SwiftUI actually
            // re-render between them, which is the condition a gesture-teardown
            // bug needs in order to reproduce at all.
            let pending = queue
            let useTimer = ProcessInfo.processInfo.environment["DEXTER_VISION_SELFTEST_TIMER"] != nil
            if useTimer {
                var rest = pending
                let timer = Timer(timeInterval: Double(gapMS) / 1000, repeats: true) { t in
                    guard !rest.isEmpty else { t.invalidate(); return }
                    NSApp.postEvent(rest.removeFirst(), atStart: false)
                }
                RunLoop.main.add(timer, forMode: .common)
            } else {
                // From a background thread on purpose. The main thread is inside
                // AppKit's tracking loop, blocked in `nextEventMatchingMask`; a
                // post from off-thread wakes it with each event as it arrives,
                // which is the only way to get REALISTIC spacing. Posting from
                // the main thread instead means the loop drains the queue, finds
                // it empty, exits, and orphans everything posted afterwards —
                // an artefact that looks exactly like a torn-down gesture.
                DispatchQueue.global().async {
                    for e in pending {
                        NSApp.postEvent(e, atStart: false)
                        usleep(UInt32(gapMS) * 1000)
                    }
                }
            }
        }

        try? await Task.sleep(for: .milliseconds(2000 + gapMS * queue.count))
        VisionProbe.line("selftest.done")
        if takeFocus {
            CGWarpMouseCursorPosition(cursorBefore)
            NSApp.hide(nil)
        }
    }
}
#endif

import SwiftUI

/// Whether an attachment is being read anywhere in the app right now (#416).
///
/// The task editor on macOS is a popover, which is its own window. While it reads a
/// file it puts a notice over its own form, but the window behind it carries on
/// looking live and clickable, and the operation reads as smaller than it is: you
/// pressed Add, went to Finder, came back, and the app looks idle apart from one
/// small card.
///
/// So the window dims and stops taking clicks for the duration. That is the same
/// promise the blocking notice makes inside the editor, extended to the surface the
/// editor is floating over.
///
/// A singleton rather than state threaded through the view tree because the two ends
/// are far apart: the reader is a section inside a popover's hosting controller, and
/// the dimmer is the section root several levels up in a different window. Threading
/// a binding between them would mean touching every view in between for something
/// neither of them owns.
@MainActor
@Observable
final class TaskAttachmentActivity {
    static let shared = TaskAttachmentActivity()

    /// The read in flight, or nil. Carries `isPDF` so a caller that wants to describe
    /// it can, without keeping a second piece of state that could disagree.
    private(set) var reading: TaskReadingNotice?

    var isReading: Bool { reading != nil }

    private init() {}

    func began(isPDF: Bool) {
        reading = TaskReadingNotice(isPDF: isPDF)
    }

    func ended() {
        reading = nil
    }
}

/// Dim and disable this surface while an attachment is being read (#416).
///
/// Scoped to the section content, so window chrome and the toolbar stay live — the
/// point is to say "the app is busy with this", not to trap anyone. The editor
/// popover is a separate window and is deliberately NOT dimmed by this: it is the
/// thing you are meant to be looking at.
struct AttachmentReadingDimmer: ViewModifier {
    @State private var activity = TaskAttachmentActivity.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if activity.isReading {
                    Rectangle()
                        .fill(.black.opacity(0.35))
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(!activity.isReading)
            .animation(.easeOut(duration: 0.2), value: activity.isReading)
    }
}

extension View {
    /// See `AttachmentReadingDimmer`.
    func dimsWhileReadingAnAttachment() -> some View {
        modifier(AttachmentReadingDimmer())
    }
}

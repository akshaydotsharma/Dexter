import Foundation

/// The rules behind the note editor's autosave (#455).
///
/// Extracted from `NoteDetailContent` so they can be tested. The view owns the
/// timer and the SwiftData write; everything here is a pure decision about
/// WHAT counts as unsaved and HOW LONG to wait before writing it.
enum NoteAutosave {

    /// Idle gap after the last edit before the note is written.
    static let idle: TimeInterval = 1.2

    /// The longest the first unsaved edit may wait, however fast the input
    /// keeps coming.
    ///
    /// Without this ceiling a pure idle debounce starves: dictation streams
    /// tokens into the body with no pause long enough to fire, so the timer
    /// restarts forever and the text is still unsaved when the app dies. That
    /// is the failure this issue is about, so the debounce must not be able to
    /// reintroduce it.
    static let maxWait: TimeInterval = 6

    /// How long to wait before writing, for an edit made at `now` in a run of
    /// unsaved edits that began at `dirtySince`.
    ///
    /// The idle gap, clamped so the write lands no later than
    /// `dirtySince + maxWait`. Never negative: a run that has already outlived
    /// the ceiling writes immediately.
    static func wait(dirtySince: Date, now: Date) -> TimeInterval {
        let spent = now.timeIntervalSince(dirtySince)
        return min(idle, max(0, maxWait - spent))
    }
}

/// What the editor holds, in the shape the store keeps it.
///
/// The editor works in non-optional `String`s because that is what a text field
/// binds to, while a note stores `nil` for "no title" and "no body". Comparing
/// the two directly is how a note with an empty title reads as permanently
/// unsaved, so normalise first and compare the normalised values.
struct NoteDraft: Equatable {
    let title: String?
    let content: String?
    let folderId: UUID?

    /// - Parameters:
    ///   - title: the raw title field. Trimmed; empty becomes nil.
    ///   - content: the raw body. Empty becomes nil; NOT trimmed, because
    ///     leading and trailing blank lines are the writer's, not noise.
    init(title: String, content: String, folderId: UUID?) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        self.title = trimmed.isEmpty ? nil : title
        self.content = content.isEmpty ? nil : content
        self.folderId = folderId
    }

    /// The already-normalised form, for describing what is on disk.
    init(savedTitle: String?, savedContent: String?, folderId: UUID?) {
        self.title = savedTitle
        self.content = savedContent
        self.folderId = folderId
    }
}

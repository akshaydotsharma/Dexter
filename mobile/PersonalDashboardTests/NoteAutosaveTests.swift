import XCTest
@testable import PersonalDashboard

/// The note editor's autosave (#455).
///
/// The bug: leaving the view was the only save. `.onDisappear` does not fire
/// when iOS terminates the app, so a crash, a memory reclaim while backgrounded,
/// or a swipe-away from the app switcher discarded an entire writing session and
/// left no trace of it — the row's `updatedAt` never moved, and the backup that
/// runs on backgrounding archived the note without the text.
///
/// The timer and the SwiftData write live in the view. What is asserted here is
/// the pair of decisions that make the timer safe: how long a write may be
/// deferred, and what counts as unsaved.
final class NoteAutosaveTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - How long the write may wait

    /// The ordinary case: a keystroke in a fresh run waits out the idle gap.
    func testFreshEditWaitsTheIdleGap() {
        XCTAssertEqual(NoteAutosave.wait(dirtySince: start, now: start), NoteAutosave.idle, accuracy: 0.001)
    }

    /// Still the idle gap while the run is young. Each keystroke restarts the
    /// timer, which is the point of a debounce.
    func testEditEarlyInTheRunStillWaitsTheIdleGap() {
        let now = start.addingTimeInterval(2)
        XCTAssertEqual(NoteAutosave.wait(dirtySince: start, now: now), NoteAutosave.idle, accuracy: 0.001)
    }

    /// The ceiling: input that never pauses must not defer the write forever.
    /// Once the run is within one idle gap of `maxWait`, the wait shortens so
    /// the write lands exactly at the ceiling.
    func testWaitShortensSoTheWriteLandsAtTheCeiling() {
        let now = start.addingTimeInterval(NoteAutosave.maxWait - 0.4)
        let wait = NoteAutosave.wait(dirtySince: start, now: now)
        XCTAssertEqual(wait, 0.4, accuracy: 0.001)
        XCTAssertEqual(now.addingTimeInterval(wait).timeIntervalSince(start),
                       NoteAutosave.maxWait,
                       accuracy: 0.001)
    }

    /// A run that has already outlived the ceiling writes immediately rather
    /// than sleeping a negative interval, which would trap.
    func testWaitNeverGoesNegative() {
        let now = start.addingTimeInterval(NoteAutosave.maxWait + 30)
        XCTAssertEqual(NoteAutosave.wait(dirtySince: start, now: now), 0, accuracy: 0.001)
    }

    /// The ceiling has to be the longer of the two, or the idle gap could never
    /// elapse and every save would be a max-wait save.
    func testCeilingIsLongerThanTheIdleGap() {
        XCTAssertGreaterThan(NoteAutosave.maxWait, NoteAutosave.idle)
    }

    // MARK: - What counts as unsaved

    /// Opening a note and closing it again must write nothing. The editor holds
    /// `""` where the note holds nil, so a naive comparison would report every
    /// untitled note as dirty forever and touch `updatedAt` on every open.
    func testLoadedNoteIsNotDirty() {
        let folder = UUID()
        let saved = NoteDraft(savedTitle: nil, savedContent: "Met with Amit.", folderId: folder)
        let draft = NoteDraft(title: "", content: "Met with Amit.", folderId: folder)
        XCTAssertEqual(draft, saved)
    }

    /// A title of nothing but spaces is no title.
    func testWhitespaceOnlyTitleNormalisesToNil() {
        XCTAssertNil(NoteDraft(title: "   ", content: "body", folderId: nil).title)
    }

    /// A real title is kept as typed, not trimmed into a different string.
    func testTitleKeepsItsOwnSpacing() {
        XCTAssertEqual(NoteDraft(title: " Adyen ", content: "", folderId: nil).title, " Adyen ")
    }

    /// An empty body is no body, matching what `create` and `update` store.
    func testEmptyContentNormalisesToNil() {
        XCTAssertNil(NoteDraft(title: "Adyen", content: "", folderId: nil).content)
    }

    /// Blank lines at the end of a body belong to the writer. Trimming them
    /// would make the draft compare equal to the saved copy and silently drop
    /// the newlines someone just typed.
    func testTrailingNewlinesAreARealChange() {
        let saved = NoteDraft(savedTitle: nil, savedContent: "Round 2 notes", folderId: nil)
        let draft = NoteDraft(title: "", content: "Round 2 notes\n\n", folderId: nil)
        XCTAssertNotEqual(draft, saved)
    }

    /// The reported loss, reduced: one character typed into an existing note.
    func testASingleTypedCharacterIsDirty() {
        let saved = NoteDraft(savedTitle: "Adyen", savedContent: "Recruiter call.", folderId: nil)
        let draft = NoteDraft(title: "Adyen", content: "Recruiter call.\nR", folderId: nil)
        XCTAssertNotEqual(draft, saved)
    }

    /// Moving a note between folders is an edit too, and the picker is reachable
    /// without touching either text field.
    func testFolderChangeIsDirty() {
        let saved = NoteDraft(savedTitle: "Adyen", savedContent: "Notes", folderId: nil)
        let draft = NoteDraft(title: "Adyen", content: "Notes", folderId: UUID())
        XCTAssertNotEqual(draft, saved)
    }

    /// Writing then deleting back to where you started leaves nothing to save,
    /// so a pending tick that fires afterwards must not touch the row.
    func testEditedBackToTheSavedTextIsClean() {
        let saved = NoteDraft(savedTitle: "Adyen", savedContent: "Notes", folderId: nil)
        let draft = NoteDraft(title: "Adyen", content: "Notes", folderId: nil)
        XCTAssertEqual(draft, saved)
    }
}

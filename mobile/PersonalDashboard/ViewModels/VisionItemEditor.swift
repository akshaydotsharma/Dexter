import Foundation
import Observation

/// Which item on the board holds the caret, and what happens when it lets go
/// (#446).
///
/// ### Why this is not `@State` on the card
///
/// It was, and it shipped a bug that could not be reproduced by anything but a
/// person clicking twice. Adding a second item left the new row uneditable: the
/// old field was still first responder (a SwiftUI `Button` does not take focus
/// on macOS), so it only tore down AFTER the new item had taken the caret, and
/// its teardown commit then cleared the caret it did not own. The first add
/// worked because there was no field to tear down.
///
/// That is an ORDERING bug between two callbacks, which is exactly the class of
/// thing a unit test states in three lines and a human finds by accident. So the
/// rules live here, in a `@MainActor` class a test can construct against a real
/// store and drive in whatever order it likes. The views became renderers: they
/// report what happened and never decide what it means.
///
/// One editor for the whole board, not one per card. There is one caret on
/// screen, so there is one place that knows where it is — which also means the
/// overflow popover and the card cannot disagree about whether something is
/// being edited.
///
/// ### The rule that fixes the bug
///
/// **Only the row that currently owns the caret may release it.** Every commit
/// still WRITES (the text was typed, it must not be lost), but a commit arriving
/// from a row the caret has already left does not touch focus. That makes the
/// two possible orderings — resign-then-add, and add-then-resign — produce the
/// same result, which is the only way this stops being a race.
@MainActor
@Observable
final class VisionItemEditor {
    /// Where a row is drawn. The same item appears on the card AND in the
    /// overflow popover, so "which item holds the caret" is not enough — the
    /// answer has to name a place.
    ///
    /// Without this, typing a new item and then clicking `+N more` destroyed
    /// what you had typed. Both surfaces consulted a bare `editingID`, so both
    /// mounted a text field for the same item. The popover's copy came up blank
    /// (its draft is seeded from the stored text, which was still empty), took
    /// the caret, and when the card's field then committed the real text and
    /// released the caret, the popover's blank field tore down and reported ""
    /// — and empty text removes an item. Created, saved, deleted, in one click.
    ///
    /// One caret, in one place. The card renders a field only for
    /// `editingID(in: .card)`, the popover only for `editingID(in: .popover)`,
    /// so a second field for the same row cannot exist to report anything.
    enum Surface: Hashable {
        case card
        case popover
    }

    /// The item holding the caret and where it is being drawn, or nil.
    private(set) var editing: (id: UUID, surface: Surface)?

    /// The item holding the caret anywhere. For callers that only need to know
    /// whether an edit is in flight (the card's auto-close guard, tests).
    var editingID: UUID? { editing?.id }

    /// The item holding the caret ON `surface`, which is what a view must ask:
    /// answering for the other surface is what mounted two fields for one row.
    func editingID(in surface: Surface) -> UUID? {
        guard let editing, editing.surface == surface else { return nil }
        return editing.id
    }

    private let viewModel: VisionBoardViewModel

    init(viewModel: VisionBoardViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Beginning

    /// Put the caret in an existing item, because its text was clicked.
    ///
    /// Deliberately does not commit whatever was being edited before. It cannot:
    /// the in-progress text lives in the `NSTextField`, not here. The outgoing
    /// row commits itself when its field tears down, which is the same path that
    /// already works, and the ownership rule makes that commit harmless whenever
    /// it happens to land.
    func begin(_ id: UUID, in surface: Surface) {
        editing = (id, surface)
    }

    /// Make a blank item on `blockID` and put the caret in it.
    ///
    /// Blank on purpose: the row appears already in edit and is typed into. An
    /// add that is then abandoned removes itself on commit, so nothing is left
    /// behind — see `commit`.
    ///
    /// There is deliberately no in-flight guard against a double click. One was
    /// written and removed: it wrapped an `await` that does not reliably suspend
    /// (everything from here to the store save is `@MainActor`), so it fired
    /// sometimes and not others, which is worse than not existing. It is also
    /// unnecessary. A second click makes a second row and moves the caret, which
    /// tears down the first row's field, which reports empty text, which removes
    /// it — the ordinary commit path, arriving at the right answer on its own.
    /// `testASecondAddRemovesTheBlankRowItAbandoned` is that claim.
    func addItem(to blockID: UUID, in surface: Surface = .card) async {
        guard let id = await viewModel.addItem(to: blockID) else { return }
        editing = (id, surface)
    }

    // MARK: - Ending

    /// An item reports its final text.
    ///
    /// Called on Return and on blur, and blur includes the field being torn down
    /// by a re-render — which is why this may arrive for a row the caret has
    /// already left.
    ///
    /// - Parameters:
    ///   - continuing: true when Return was pressed. Non-empty text then opens a
    ///     fresh item below, so a list can be typed without reaching for the
    ///     mouse between lines. Empty text ends the run instead, which is how you
    ///     stop: Return on a blank row.
    func commit(
        _ id: UUID,
        in blockID: UUID,
        text: String,
        continuing: Bool = false,
        surface: Surface = .card
    ) async {
        // Both halves. Matching only the id was the original bug wearing a new
        // hat: the card's late blur for row X would release a caret the POPOVER
        // had since taken on that same row X, and the field you were typing in
        // would go dead under you.
        let owned = editing?.id == id && editing?.surface == surface
        // Released BEFORE the awaits below. If it were released after, a commit
        // and an add could interleave and this would clear a caret the add had
        // meanwhile placed on a different row — the original bug, moved rather
        // than fixed.
        if owned { editing = nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Emptied, or created and abandoned. Both mean the same thing and
            // both have to remove the row — checked FIRST, because a blank item
            // that was never typed into already matches `currentText` and the
            // unchanged-text short circuit below would leave it on the block
            // forever.
            await viewModel.deleteItem(id, from: blockID)
        } else if trimmed != currentText(of: id, in: blockID) {
            // Unchanged text writes nothing. Clicking an item and clicking away
            // should not bump `updatedAt` and make the block look edited.
            await viewModel.setItemText(id, in: blockID, to: trimmed)
        }

        // Only continue from a row that had something on it, and only if the
        // caret was still ours to move. Chaining off a commit we did not own
        // would open a new item because a DIFFERENT row happened to blur.
        guard continuing, owned, !trimmed.isEmpty else { return }
        await addItem(to: blockID, in: surface)
    }

    /// Escape: leave the item as it was.
    ///
    /// A blank item is removed, because a blank row is not a thing anyone meant
    /// to keep and Escape on a just-created one has to undo the creation. An item
    /// with text keeps that text: the field discards its own edit, so there is
    /// nothing here to roll back.
    func cancel(_ id: UUID, in blockID: UUID) async {
        if editing?.id == id { editing = nil }
        guard currentText(of: id, in: blockID).isEmpty else { return }
        await viewModel.deleteItem(id, from: blockID)
    }

    // MARK: - Internals

    /// What the store currently thinks this item says. Empty when it is gone,
    /// which makes a commit for a deleted item a no-op rather than a resurrection.
    private func currentText(of id: UUID, in blockID: UUID) -> String {
        guard let block = viewModel.blocks.first(where: { $0.id == blockID }) else { return "" }
        guard let item = block.items.first(where: { $0.id == id }) else { return "" }
        return item.text
    }
}

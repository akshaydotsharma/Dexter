import XCTest
@testable import PersonalDashboard

/// The attachment row's kind word (#466).
///
/// Since #466 an attachment is a plain row rather than a wallet-style pass, and
/// the second line has to say what kind of file it is. That reduces to one
/// ordering question with a real trap in it: a `.pkpass` is a signed zip, so it
/// is neither a PDF nor an image, and every check order except "pass first"
/// files it under the wrong one. The same ordering bug in the thumbnail drew the
/// grey missing-file placeholder over a file that was present and valid, which
/// reads as data loss.
///
/// Cheap to pin, invisible to a build, and the sort of thing a later refactor
/// reorders without thinking.
final class AttachmentRowTests: XCTestCase {

    func testAPassIsNamedAPassAndNotAPDF() {
        XCTAssertEqual(TaskAttachmentRow.kindWord(for: "task-tickets/abc.pkpass"), "Pass")
    }

    func testAPDFIsNamedAPDF() {
        XCTAssertEqual(TaskAttachmentRow.kindWord(for: "task-tickets/abc.pdf"), "PDF")
    }

    func testAPhotoIsNamedAnImage() {
        XCTAssertEqual(TaskAttachmentRow.kindWord(for: "task-tickets/abc.jpg"), "Image")
    }

    /// Where a tap on an attachment row goes (#473).
    ///
    /// The rule is "clicking a document produces the document", with one exception
    /// that is not a hedge: a `.pkpass` is a signed zip with no page to render, so
    /// the viewer would draw its "no longer available" state over a file that is
    /// present and valid. The details sheet is the only surface that can act on a
    /// pass, because it carries Add to Apple Wallet.
    ///
    /// Pinned because the predicate is shared with the detail sheet's own preview
    /// gate, and the two silently disagreeing is exactly the #466 bug where the
    /// grey missing-file placeholder was drawn over a valid pass.
    @MainActor
    func testAPassOpensItsDetailsAndEveryOtherFileOpensTheFile() {
        XCTAssertTrue(TicketStorage.isPass("task-tickets/abc.pkpass"))
        XCTAssertFalse(TicketStorage.isPass("task-tickets/abc.pdf"))
        XCTAssertFalse(TicketStorage.isPass("task-tickets/abc.jpg"))
    }

    /// A row can carry a decoded payload with no file behind it, and calling that
    /// "Image" would promise a preview that can never load.
    func testARowWithNoFileSaysSo() {
        XCTAssertEqual(TaskAttachmentRow.kindWord(for: ""), "Barcode only")
        XCTAssertEqual(TaskAttachmentRow.kindWord(for: "   "), "Barcode only")
    }

    /// The missing-file case outranks the kind. The row synced across from another
    /// device but its bytes did not, and that is worth saying in words: an
    /// unexplained placeholder reads as a bug rather than as a file that is
    /// simply elsewhere.
    ///
    /// Since #471 the bytes do follow the row, so this sentence is the case where
    /// no peer has published them. The arriving variant is covered in
    /// `SyncAssetTransferTests`.
    func testAnAbsentFileIsExplainedRatherThanLabelled() {
        let ticket = TaskTicket(
            id: UUID(),
            todoId: UUID(),
            attachmentPath: "task-tickets/abc.pdf",
            barcodePayload: "",
            barcodeSymbology: "",
            eventTitle: "Odette",
            eventDate: nil,
            startTimeText: "",
            venue: "",
            seat: "",
            gate: "",
            reference: "",
            ticketMetaJSON: "",
            position: 0,
            createdAt: .now,
            updatedAt: .now,
            deletedAt: nil
        )
        XCTAssertEqual(
            TaskAttachmentRow.subtitle(for: ticket, fileIsPresent: false),
            "File on your other device"
        )
    }
}

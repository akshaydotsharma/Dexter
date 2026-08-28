import XCTest
import SwiftData
@testable import PersonalDashboard

/// Clearing a task's Notes or Tag (#488).
///
/// The defect was invisible to a build and to a screenshot: the editor closed
/// cleanly, the write succeeded, and the old text was simply still there on the
/// next open. It came from one value carrying two meanings. `nil` means "leave the
/// stored value alone" in `TodoService.update`, because the inline rename rows pass
/// a task's own notes and tag straight back through it. The editor also collapsed
/// an emptied field to `nil`, so "the user deleted this" and "the caller is not
/// touching this" arrived as the same request and untouched won.
///
/// Both halves are asserted, because either one alone leaves the bug in place: the
/// editor has to SAY "" for a cleared field, and the service has to store that ""
/// as an absent value rather than as an empty string on the row.
@MainActor
final class TaskFieldClearingTests: XCTestCase {

    private var store: SwiftDataStore!
    private var service: TodoService!

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = TodoService(store: store)
    }

    override func tearDown() async throws {
        service = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - What the editor sends

    /// The regression itself. Before the fix this returned `nil`, which the service
    /// reads as "leave it alone", so the note the user had just deleted survived.
    func testEditingSendsAnEmptyStringForAClearedField() {
        XCTAssertEqual(TaskEditorSheet.savedValue("", isEditing: true), "")
    }

    /// A new task has nothing to clear, so it keeps sending nil and the column stays
    /// absent rather than holding "".
    func testCreatingSendsNilForABlankField() {
        XCTAssertNil(TaskEditorSheet.savedValue("", isEditing: false))
    }

    func testTypedTextIsSentAsIsOnBothPaths() {
        XCTAssertEqual(TaskEditorSheet.savedValue("Call the vet", isEditing: true), "Call the vet")
        XCTAssertEqual(TaskEditorSheet.savedValue("Call the vet", isEditing: false), "Call the vet")
    }

    // MARK: - What the service does with it

    func testEmptyDescriptionClearsTheStoredNotes() async throws {
        let todo = try await service.create(
            TodoCreateRequest(title: "Renew passport", description: "Take the old one", dueDate: nil, tag: nil)
        )

        let updated = try await service.update(todo, request(description: ""))

        XCTAssertNil(updated.description, "an emptied Notes field must clear the stored note")
    }

    func testEmptyTagClearsTheStoredTag() async throws {
        let todo = try await service.create(
            TodoCreateRequest(title: "Renew passport", description: nil, dueDate: nil, tag: "admin")
        )

        let updated = try await service.update(todo, request(tag: ""))

        XCTAssertNil(updated.tag, "an emptied Tag field must clear the stored tag")
    }

    /// The reason "" and nil cannot be the same value: the inline rename rows pass a
    /// task's own notes and tag back in, and must leave both exactly as they were.
    func testNilLeavesNotesAndTagUntouched() async throws {
        let todo = try await service.create(
            TodoCreateRequest(title: "Renew passport", description: "Take the old one", dueDate: nil, tag: "admin")
        )

        let updated = try await service.update(todo, request(title: "Renew passport now"))

        XCTAssertEqual(updated.title, "Renew passport now")
        XCTAssertEqual(updated.description, "Take the old one")
        XCTAssertEqual(updated.tag, "admin")
    }

    func testNonEmptyValuesStillOverwrite() async throws {
        let todo = try await service.create(
            TodoCreateRequest(title: "Renew passport", description: "Take the old one", dueDate: nil, tag: "admin")
        )

        let updated = try await service.update(todo, request(description: "Bring two photos", tag: "travel"))

        XCTAssertEqual(updated.description, "Bring two photos")
        XCTAssertEqual(updated.tag, "travel")
    }

    /// A cleared note must read back as absent, not as "", so a card that only
    /// unwraps the optional cannot render a blank line where the note used to be.
    func testAClearedNoteReadsBackAsAbsentFromTheList() async throws {
        let todo = try await service.create(
            TodoCreateRequest(title: "Renew passport", description: "Take the old one", dueDate: nil, tag: "admin")
        )
        _ = try await service.update(todo, request(description: "", tag: ""))

        let listed = try await service.list()
        let row = try XCTUnwrap(listed.first { $0.id == todo.id })
        XCTAssertNil(row.description)
        XCTAssertNil(row.tag)
    }

    // MARK: - Helpers

    private func request(
        title: String? = nil,
        description: String? = nil,
        tag: String? = nil
    ) -> TodoUpdateRequest {
        TodoUpdateRequest(
            title: title,
            description: description,
            completed: nil,
            dueDate: nil,
            tag: tag
        )
    }
}

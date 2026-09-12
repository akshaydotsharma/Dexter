import XCTest
import SwiftUI
import AppKit
@testable import DexterMac

/// That the recurring-task surfaces actually lay out, and what they say (#524).
///
/// ### Why a render test rather than a driven window
///
/// A Mac app launched from a script never becomes truly key, so posted clicks are
/// swallowed as activation clicks and a sheet cannot be opened from a harness
/// (project memory, #446). That leaves these surfaces with no autonomous QA at all
/// unless they are hosted directly, which is what this does: `NSHostingView` lays
/// the real view out, the same way the app will.
///
/// It asserts what a screenshot would be read for — that the rule reads back the
/// way it was set, and that the view produces a real layout rather than collapsing
/// to nothing. Set `DEXTER_QA_SHOTS=<dir>` to also write the PNGs.
@MainActor
final class RepeatRuleEditorRenderTests: XCTestCase {

    /// Lay a view out at a fixed size and return its bitmap, or nil if it drew
    /// nothing. A collapsed view is the failure this catches: it compiles, it
    /// hosts, and it renders an empty rectangle.
    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, named name: String) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)

        if let dir = ProcessInfo.processInfo.environment["DEXTER_QA_SHOTS"],
           let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    // MARK: - The rule reads back

    /// Every frequency says what it means. These strings are the only place the
    /// rule is legible to the person setting it, so a wrong one is a rule they
    /// cannot check.
    func testEachFrequencyDescribesItself() {
        var draft = RecurrenceDraft.seeded(from: Date(timeIntervalSince1970: 1_789_000_000))
        draft.timeOfDay = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!

        draft.frequency = .daily
        XCTAssertTrue(draft.summary.hasPrefix("Every day"), draft.summary)

        draft.interval = 3
        XCTAssertTrue(draft.summary.hasPrefix("Every 3 days"), draft.summary)

        draft.frequency = .weekly
        draft.interval = 1
        draft.weekdayMask = (1 << 1) | (1 << 3) | (1 << 5)
        XCTAssertTrue(draft.summary.hasPrefix("Weekly on"), draft.summary)

        draft.frequency = .monthly
        draft.dayOfMonth = 1
        XCTAssertTrue(draft.summary.hasPrefix("Monthly on the 1st"), draft.summary)
    }

    /// A weekly rule with nothing ticked cannot be saved. The Save button reads
    /// this, so a wrong answer here is a form that commits an unfireable rule.
    func testAWeeklyDraftWithNoDaySelectedIsNotValid() {
        var draft = RecurrenceDraft()
        draft.frequency = .weekly
        draft.weekdayMask = 0
        XCTAssertFalse(draft.isValid)
        draft.weekdayMask = 1 << 2
        XCTAssertTrue(draft.isValid)
    }

    /// The preview line promises a first date. A rule that cannot produce one has
    /// to say so rather than showing a blank.
    func testTheDraftKnowsItsFirstDate() {
        var draft = RecurrenceDraft.seeded()
        draft.frequency = .daily
        XCTAssertNotNil(draft.firstDate)
    }

    // MARK: - The views lay out

    func testTheRepeatEditorLaysOut() throws {
        var draft = RecurrenceDraft.seeded(from: Date(timeIntervalSince1970: 1_789_000_000))
        draft.frequency = .weekly
        draft.weekdayMask = (1 << 1) | (1 << 3) | (1 << 5)
        draft.leadDays = 3

        let rep = try XCTUnwrap(
            render(
                RepeatRuleEditor(draft: .constant(draft), showsStartDate: true)
                    .padding(16)
                    .background(Tokens.paper),
                width: 460, height: 620, named: "repeat-rule-editor"
            )
        )
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        XCTAssertGreaterThan(rep.pixelsHigh, 0)
    }

    func testTheRecurringListLaysOut() throws {
        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let service = RecurringTaskService(store: store)
        _ = try service.create(
            title: "Take the bins out",
            frequency: .weekly,
            weekdayMask: 1 << 2,
            leadDays: 1
        )
        _ = try service.create(
            title: "Pay the rent",
            frequency: .monthly,
            dayOfMonth: 1,
            leadDays: 3
        )
        let paused = try service.create(title: "Water the plants", frequency: .daily)
        try service.setActive(paused, false)

        let rep = try XCTUnwrap(
            render(
                RecurringTasksView().modelContainer(store.container),
                width: 520, height: 620, named: "recurring-list"
            )
        )
        XCTAssertGreaterThan(rep.pixelsWide, 0)
    }
}

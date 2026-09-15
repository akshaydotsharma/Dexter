import XCTest
import SwiftUI
import SwiftData
import AppKit
@testable import DexterMac

/// Coverage for #578: every remaining `paperFieldOnMac()` call site whose
/// field carries a non-empty title now routes through `plainFieldPlaceholder`,
/// the same helper #576 shipped for the two Meals fields.
///
/// One converted field per surface, per the ticket's own bar ("do not write
/// 55 tests"). Each test follows the pattern `MealComposerPlaceholderTests`
/// set: host the real production view off-screen, find the AppKit
/// `NSTextField` it produces, and check two things pixels are the only honest
/// witness to:
///
/// 1. The field is genuinely empty on a fresh mount (never the example text).
/// 2. Whatever draws the placeholder renders muted, not near-ink.
///
/// Chat has no test here: `ChatInputBar`'s one `paperFieldOnMac()` call site
/// already passes an empty title with its own hand-rolled overlay, so #578
/// left it untouched — there is nothing "converted" there to regress.
@MainActor
final class PlainFieldPlaceholderCoverageTests: XCTestCase {

    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        // Off the visible screen: this must not steal the desktop while it runs.
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 560, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
        try await super.tearDown()
    }

    // MARK: - Hosting

    /// A fresh in-memory store per test, so nothing here ever touches the
    /// real on-disk singleton (`SwiftDataStore.shared`) or the app's own
    /// SwiftData rows.
    private func makeInMemoryContainer() -> ModelContainer {
        SwiftDataStore.makeInMemory()
    }

    private func host<V: View>(_ view: V) async -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        window.contentView = host
        window.setIsVisible(true)
        await settle(host)
        return host
    }

    private func settle(_ view: NSView, _ turns: Int = 20) async {
        for _ in 0..<turns {
            view.layoutSubtreeIfNeeded()
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// The first `NSTextField` (or `NSSecureTextField`, a subclass) found in
    /// depth-first traversal order. Right for every surface below except
    /// Settings, which renders one field ahead of the one under test.
    private func firstField(in view: NSView) -> NSTextField? {
        allFields(in: view).first
    }

    /// Every text field in the hierarchy, in depth-first traversal order —
    /// which matches declaration order for the plain `VStack`/`ScrollView`
    /// layouts every surface here uses.
    private func allFields(in view: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        if let field = view as? NSTextField { result.append(field) }
        for sub in view.subviews { result.append(contentsOf: allFields(in: sub)) }
        return result
    }

    // MARK: - Pixels (identical method to MealComposerPlaceholderTests, #576)

    private func luminance(of color: Color) -> Double {
        var result = 1.0
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            result = 0.299 * rgb.redComponent
                + 0.587 * rgb.greenComponent
                + 0.114 * rgb.blueComponent
        }
        return result
    }

    private func darkestLuminance(of view: NSView, in rect: NSRect) -> Double? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = Double(rep.pixelsWide) / Double(view.bounds.width)
        let minX = max(0, Int(rect.minX * scale))
        let maxX = min(rep.pixelsWide - 1, Int(rect.maxX * scale))
        let minY = max(0, Int(rect.minY * scale))
        let maxY = min(rep.pixelsHigh - 1, Int(rect.maxY * scale))
        guard minX < maxX, minY < maxY else { return nil }

        var darkest = 1.0
        var drawn = 0
        for y in minY...maxY {
            for x in minX...maxX {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let alpha = c.alphaComponent
                let lum = (0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent)
                    * alpha + (1 - alpha)
                if lum > 0.90 { continue }   // the paper and its hairline border
                drawn += 1
                darkest = min(darkest, lum)
            }
        }
        return drawn > 0 ? darkest : nil
    }

    /// Shared assertion: the field must hold nothing, and whatever draws its
    /// placeholder must sit closer to `Tokens.mutedSoft` than to `Tokens.ink`.
    private func assertEmptyAndMuted(
        field: NSTextField,
        host: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(field.stringValue, "", "the field holds no content on a fresh mount", file: file, line: line)
        XCTAssertTrue(
            (field.placeholderString ?? "").isEmpty,
            "macOS draws the placeholder itself; AppKit's own placeholder stays empty",
            file: file, line: line
        )

        let inkLuminance = luminance(of: Tokens.ink)
        let mutedLuminance = luminance(of: Tokens.mutedSoft)
        let gate = (inkLuminance + mutedLuminance) / 2

        let rect = field.convert(field.bounds, to: host).insetBy(dx: -4, dy: -4)
        let darkest = try XCTUnwrap(
            darkestLuminance(of: host, in: rect),
            "the placeholder is drawn somewhere in the field",
            file: file, line: line
        )
        XCTAssertGreaterThan(
            darkest, gate,
            """
            the placeholder renders at luminance \(darkest), darker than the gate \
            \(gate) between muted (\(mutedLuminance)) and ink (\(inkLuminance)). \
            It reads as typed content rather than as a placeholder.
            """,
            file: file, line: line
        )
    }

    // MARK: - Finance: RenamePersonSheet's "Name" field

    /// A person with no name is an unusual row, not a state the app would
    /// ever create on its own, but it is the cleanest way to drive the field
    /// empty: `RenamePersonSheet` seeds `name` from `person.name` on appear,
    /// so an empty person keeps the field empty for the assertion.
    func testFinanceRenamePersonSheetNameFieldDrawsAMutedPlaceholder() async throws {
        let person = LocalPerson(name: "", colorHex: "10B981")
        let host = await host(RenamePersonSheet(person: person))
        let field = try XCTUnwrap(firstField(in: host), "RenamePersonSheet hosts a text field")
        try assertEmptyAndMuted(field: field, host: host)
    }

    // MARK: - Tasks: RecurringTaskEditorSheet's "Title" field

    func testTasksRecurringTaskEditorTitleFieldDrawsAMutedPlaceholder() async throws {
        let container = makeInMemoryContainer()
        let host = await host(
            RecurringTaskEditorSheet(template: nil)
                .modelContainer(container)
        )
        let field = try XCTUnwrap(firstField(in: host), "RecurringTaskEditorSheet hosts a text field")
        try assertEmptyAndMuted(field: field, host: host)
    }

    // MARK: - Trips: ItineraryItemEditorSheet's "Title" field

    func testTripsItineraryItemEditorTitleFieldDrawsAMutedPlaceholder() async throws {
        let container = makeInMemoryContainer()
        let trip = LocalTrip(name: "Test Trip", startDate: Date(), endDate: Date())
        let host = await host(
            ItineraryItemEditorSheet(trip: trip, target: .new(day: Date()))
                .modelContainer(container)
        )
        let field = try XCTUnwrap(firstField(in: host), "ItineraryItemEditorSheet hosts a text field")
        try assertEmptyAndMuted(field: field, host: host)
    }

    // MARK: - Wallet: WalletCardEditorSheet's "Title" field

    func testWalletCardEditorTitleFieldDrawsAMutedPlaceholder() async throws {
        let container = makeInMemoryContainer()
        let host = await host(
            WalletCardEditorSheet(target: .new)
                .modelContainer(container)
        )
        let field = try XCTUnwrap(firstField(in: host), "WalletCardEditorSheet hosts a text field")
        try assertEmptyAndMuted(field: field, host: host)
    }

    // MARK: - Notes/Lists: NewFolderSheet's "Name" field

    func testNotesNewFolderSheetNameFieldDrawsAMutedPlaceholder() async throws {
        let store = SwiftDataStore(container: makeInMemoryContainer())
        let viewModel = NotesViewModel(service: NoteService(store: store))
        let host = await host(NewFolderSheet(viewModel: viewModel))
        let field = try XCTUnwrap(firstField(in: host), "NewFolderSheet hosts a text field")
        try assertEmptyAndMuted(field: field, host: host)
    }

    // MARK: - Settings: the "Your name" field

    /// `SettingsView` renders the Anthropic API key's `SecureField` (in
    /// `AnthropicKeyRow`, ahead of Finance in the section order) before the
    /// "Your name" field, so this is the SECOND text field in the hierarchy,
    /// not the first.
    ///
    /// `userDisplayName` is `@AppStorage`-backed, so it is cleared first: a
    /// stale value left by a previous run or a real install must not make
    /// this test pass by accident.
    func testSettingsYourNameFieldDrawsAMutedPlaceholder() async throws {
        let defaultsKey = "finance.userDisplayName"
        let previous = UserDefaults.standard.string(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        let host = await host(
            SettingsView(router: AppRouter(), schemePref: .constant(.system))
        )
        let fields = allFields(in: host)
        XCTAssertGreaterThanOrEqual(fields.count, 2, "the API key field and \"Your name\" both render")
        let field = fields[1]
        try assertEmptyAndMuted(field: field, host: host)
    }
}

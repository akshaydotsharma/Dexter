import XCTest
import SwiftUI
import AppKit
@testable import DexterMac

/// The meal composer's example meal must be a placeholder, not content (#576).
///
/// Reported: the macOS field showed *"Two eggs on toast with butter and a flat
/// white"* in full ink with a caret in front of it, so the composer looked
/// pre-filled with a breakfast nobody ate.
///
/// Two separate claims are pinned here, because they fail in different ways:
///
/// 1. **The field is empty.** If the example ever became real content, it would
///    reach `MealEstimationService` as a meal description and a day's totals
///    would move for food nobody ate. That is a correctness failure, and it is
///    silent. This is the assertion the acceptance criteria ask for.
/// 2. **The example is drawn muted.** `.textFieldStyle(.plain)` makes AppKit
///    draw a placeholder at near-ink strength, which is how the field came to
///    look pre-filled while holding nothing at all. That is a reading failure,
///    and pixels are the only honest witness to it.
///
/// The composer is hosted in a real window, because both claims are about what
/// AppKit does with the view, not about what the Swift value says.
@MainActor
final class MealComposerPlaceholderTests: XCTestCase {

    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        // Off the visible screen: this must not steal the desktop while it runs.
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 520, height: 320),
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

    private func hostComposer() async -> NSHostingView<MealComposer> {
        let composer = MealComposer(
            day: Date(),
            existingOnDay: [],
            onLogged: { _ in }
        )
        let host = NSHostingView(rootView: composer)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        window.contentView = host
        window.setIsVisible(true)
        await settle(host)
        return host
    }

    private func settle(_ host: NSView, _ turns: Int = 20) async {
        for _ in 0..<turns {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func field(in view: NSView) -> NSTextField? {
        if let found = view as? NSTextField { return found }
        for sub in view.subviews {
            if let found = field(in: sub) { return found }
        }
        return nil
    }

    // MARK: - The field holds nothing

    /// The one that keeps the example out of the estimate path.
    func testTheDescriptionFieldIsEmptyOnAFreshMount() async throws {
        let host = await hostComposer()
        let field = try XCTUnwrap(self.field(in: host), "the composer hosts a text field")

        XCTAssertEqual(field.stringValue, "", "a fresh composer holds no description")
        XCTAssertNotEqual(
            field.stringValue,
            MealComposer.placeholderExample,
            "the example meal must never be content"
        )
    }

    /// AppKit must be handed no placeholder at all, because the only treatment
    /// it offers for a plain field is the near-ink one this bug is about.
    func testAppKitIsGivenNoPlaceholderToDraw() async throws {
        let host = await hostComposer()
        let field = try XCTUnwrap(self.field(in: host), "the composer hosts a text field")

        XCTAssertTrue(
            (field.placeholderString ?? "").isEmpty,
            "macOS draws the example itself; AppKit's own placeholder stays empty"
        )
        XCTAssertTrue(
            PlainFieldPlaceholder.multilineTitle(MealComposer.placeholderExample).isEmpty,
            """
            the title half of the pair is empty. This names `multilineTitle` \
            rather than `title` because that is what the composer calls since \
            #627: a multi-line field draws its own placeholder on BOTH platforms, \
            so asserting on `title` here would keep passing while the function \
            this surface depends on broke.
            """
        )
    }

    // MARK: - The example is drawn muted

    /// The example must read as a placeholder, not as ink.
    ///
    /// The gate is derived from the two tokens rather than written as a number,
    /// so it still means the right thing if the palette moves: muted text sits
    /// above it, ink sits below it, and the near-ink treatment the plain field
    /// used to apply (luminance 0.251 against this paper) sits below it too.
    func testTheExampleIsDrawnInTheMutedPlaceholderColour() async throws {
        let host = await hostComposer()
        let field = try XCTUnwrap(self.field(in: host), "the composer hosts a text field")

        let inkLuminance = luminance(of: Tokens.ink)
        let mutedLuminance = luminance(of: Tokens.mutedSoft)
        let gate = (inkLuminance + mutedLuminance) / 2

        // The field's own frame, widened a little: the glyphs sit a couple of
        // points inside it and the overlay is positioned against the padded box.
        let rect = field.convert(field.bounds, to: host).insetBy(dx: -4, dy: -4)
        let darkest = try XCTUnwrap(
            darkestLuminance(of: host, in: rect),
            "the example is drawn somewhere in the field"
        )

        XCTAssertGreaterThan(
            darkest, gate,
            """
            the example renders at luminance \(darkest), darker than the gate \
            \(gate) between muted (\(mutedLuminance)) and ink (\(inkLuminance)). \
            It reads as a meal that was typed rather than as a placeholder.
            """
        )
    }

    // MARK: - Pixels

    /// Relative luminance of a token, resolved in the appearance under test.
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

    /// The darkest pixel drawn inside `rect`, composited onto white.
    private func darkestLuminance(of view: NSView, in rect: NSRect) -> Double? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = Double(rep.pixelsWide) / Double(view.bounds.width)
        let minX = max(0, Int(rect.minX * scale))
        let maxX = min(rep.pixelsWide - 1, Int(rect.maxX * scale))
        // `bitmapImageRepForCachingDisplay` hands back a top-left origin, which
        // is the opposite of the view's flipped-or-not coordinate space only
        // when the view is not flipped. An NSHostingView is flipped, so the two
        // agree and no y inversion is needed.
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
}

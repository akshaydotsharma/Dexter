import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import PersonalDashboard

/// How a cover fills a band that is not the artwork's own 4:1 (#441).
///
/// The bug these cover: on a wide macOS window the band stopped being 4:1 (the height
/// ceiling bites past ~528 pt of card width) and the artwork was scaled to the WIDTH
/// and centre-cropped, which cuts the buildings' base off — the one part
/// `TripCoverCrop` works hardest to preserve. The rule now is that the artwork fills
/// the band's HEIGHT at its natural ratio and its edge columns are stretched across
/// whatever is left.
///
/// Rendered rather than reasoned about: the failure was a geometry mistake that every
/// piece of the code described correctly in isolation, so an assertion about the
/// resolved pixels is the only kind that would have caught it.
@MainActor
final class TripCoverBandLayoutTests: XCTestCase {

    // MARK: - Edge columns

    func testEdgesLiftTheArtworksOwnFirstAndLastColumn() throws {
        let image = try XCTUnwrap(Self.stripedArtwork())
        let edges = try XCTUnwrap(TripCoverEdges(image: image))

        let leading = try XCTUnwrap(edges.leading.cgImageCompat)
        let trailing = try XCTUnwrap(edges.trailing.cgImageCompat)

        XCTAssertEqual(leading.width, 1)
        XCTAssertEqual(trailing.width, 1)
        XCTAssertEqual(leading.height, Self.artHeight, "an edge is the full height of the file")
        XCTAssertEqual(trailing.height, Self.artHeight)

        assertColour(Self.pixel(leading, x: 0, y: Self.artHeight / 2), isNear: .red,
                     "the leading strip must be the artwork's first column")
        assertColour(Self.pixel(trailing, x: 0, y: Self.artHeight / 2), isNear: .blue,
                     "the trailing strip must be the artwork's last column")
    }

    func testEdgesRejectADegenerateBitmap() throws {
        // One pixel wide: there is no distinct first and last column to lift.
        let single = try XCTUnwrap(Self.solidArtwork(width: 1, height: 4))
        XCTAssertNil(TripCoverEdges(image: single))
    }

    // MARK: - The band rule

    /// A band WIDER than 4:1 — the macOS case that shipped broken.
    ///
    /// The artwork must sit at its natural size against the band's height, and the
    /// space either side must carry the artwork's own edge colour rather than a crop
    /// of its middle. Asserted at the vertical centre, where the striped fixture is
    /// unambiguous.
    func testWideBandKeepsTheArtworkWholeAndExtendsItsEdges() throws {
        let image = try XCTUnwrap(Self.stripedArtwork())
        let artwork = TripCoverArtwork(image: image, edges: TripCoverEdges(image: image))

        let bandHeight: CGFloat = 100
        let bandWidth: CGFloat = 1000                       // 10:1, far wider than the file
        let rendered = try XCTUnwrap(
            Self.render(TripCoverArtworkCanvas(artwork: artwork),
                        size: CGSize(width: bandWidth, height: bandHeight))
        )

        let midY = rendered.height / 2
        let artPixels = Int(bandHeight * TripCoverMetrics.ratio)   // 400 of the 1000
        let artLeft = (rendered.width - artPixels) / 2

        assertColour(Self.pixel(rendered, x: 4, y: midY), isNear: .red,
                     "the left of a wide band is the artwork's leading column stretched")
        assertColour(Self.pixel(rendered, x: rendered.width - 5, y: midY), isNear: .blue,
                     "the right of a wide band is the artwork's trailing column stretched")
        assertColour(Self.pixel(rendered, x: artLeft + artPixels / 2, y: midY), isNear: .green,
                     "the artwork itself is centred, whole, and not scaled to the width")
    }

    /// A band NARROWER than 4:1 — the 320 pt phone, where the `minHeight` clamp lifts
    /// the band above `width / 4`. The artwork overhangs and is cropped evenly, which
    /// is what `.aspectRatio(contentMode: .fill)` did before and must keep doing: the
    /// middle stays on screen and no bare band appears at the top or bottom.
    func testNarrowBandStillFillsRatherThanLettersboxes() throws {
        let image = try XCTUnwrap(Self.stripedArtwork())
        let artwork = TripCoverArtwork(image: image, edges: TripCoverEdges(image: image))

        let rendered = try XCTUnwrap(
            Self.render(TripCoverArtworkCanvas(artwork: artwork),
                        size: CGSize(width: 288, height: 84))   // 3.43:1
        )

        for y in [2, rendered.height / 2, rendered.height - 3] {
            assertColour(Self.pixel(rendered, x: rendered.width / 2, y: y), isNear: .green,
                         "a band narrower than the artwork must be covered top to bottom")
        }
    }

    // MARK: - Fixtures

    private static let artWidth = 400
    private static let artHeight = 100      // 4:1, the shape every cached cover has

    /// Red first column, blue last column, green everywhere between. Each region is a
    /// primary so a colour-managed round trip through `ImageRenderer` cannot make one
    /// read as another.
    private static func stripedArtwork() -> PlatformImage? {
        guard let ctx = context(width: artWidth, height: artHeight) else { return nil }
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: artWidth, height: artHeight))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: artHeight))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: artWidth - 1, y: 0, width: 1, height: artHeight))
        return ctx.makeImage().map { PlatformImage.fromCGImage($0) }
    }

    private static func solidArtwork(width: Int, height: Int) -> PlatformImage? {
        guard let ctx = context(width: width, height: height) else { return nil }
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage().map { PlatformImage.fromCGImage($0) }
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Render a view to a bitmap at 1× so pixel coordinates are point coordinates.
    private static func render<V: View>(_ view: V, size: CGSize) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        return renderer.cgImage
    }

    // MARK: - Pixel reading

    private enum Primary { case red, green, blue }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y),
                                    width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    /// Loose on values, strict on which channel dominates. The point is never the
    /// exact byte — a render passes through colour management — it is which region of
    /// the artwork ended up at that coordinate.
    private func assertColour(
        _ pixel: (r: Int, g: Int, b: Int),
        isNear primary: Primary,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let (dominant, others): (Int, [Int]) = {
            switch primary {
            case .red:   return (pixel.r, [pixel.g, pixel.b])
            case .green: return (pixel.g, [pixel.r, pixel.b])
            case .blue:  return (pixel.b, [pixel.r, pixel.g])
            }
        }()
        XCTAssertTrue(
            dominant > 128 && others.allSatisfy { $0 < dominant - 40 },
            "\(message) — got r\(pixel.r) g\(pixel.g) b\(pixel.b)",
            file: file, line: line
        )
    }
}

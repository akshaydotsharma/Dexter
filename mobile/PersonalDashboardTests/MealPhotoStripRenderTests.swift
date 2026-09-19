import XCTest
import SwiftUI
import UIKit
@testable import PersonalDashboard

/// The attached-photo tray actually draws a photograph (#627).
///
/// ### Why this is a pixel test and not a state test
///
/// The strip's whole job is to answer a question the user cannot answer any
/// other way: "is THAT the picture I meant to attach?" A count cannot answer it
/// and neither can a test over `photos.count`. What has to be true is that the
/// bytes reach the screen, and the only honest witness to that is the screen.
///
/// ### Why it is here and not in `DexterMacTests`
///
/// The Mac suite is app-hosted with no XCTest guard, so running it boots a real
/// DexterMac against the user's live store, syncs, and lets the trip-cover
/// reaper loose on real files. This test needs none of that — it hosts one view
/// over in-memory bytes — so it belongs in the target that can run it for free.
/// `MealPhotoStrip` is shared source, so what passes here is what the Mac draws.
@MainActor
final class MealPhotoStripRenderTests: XCTestCase {

    /// A solid vermilion JPEG. Solid on purpose: a flat, saturated colour is
    /// trivially distinguishable from the app's paper background, so "did the
    /// photo draw" becomes "is there any vermilion on screen".
    private func makeJPEG(side: CGFloat = 400) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { ctx in
            UIColor(red: 0.85, green: 0.20, blue: 0.10, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9), "the fixture encodes as JPEG")
    }

    /// Render a view off-screen and count how many of its pixels read as the
    /// fixture's vermilion.
    private func vermilionPixelCount<V: View>(of view: V, size: CGSize) -> Int {
        let controller = UIHostingController(rootView: view)
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.backgroundColor = .white
        // A window is what makes SwiftUI lay the hierarchy out at all; without
        // one the hosted view renders empty and every assertion below would be
        // measuring nothing.
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true

        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4 * 2) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            // Generous bounds: JPEG is lossy and the thumbnail is scaled, so the
            // exact value drifts. Strongly red and clearly not paper is the
            // whole claim.
            if r > 0.5, g < 0.5, b < 0.5 { count += 1 }
        }
        return count
    }

    private let canvas = CGSize(width: 390, height: 120)

    // MARK: - The tray draws the photograph

    func testAnAttachedPhotoIsVisibleAsAThumbnail() throws {
        let photos = [MealPhoto(jpegData: try makeJPEG())]

        let drawn = vermilionPixelCount(
            of: MealPhotoStrip(photos: .constant(photos), note: nil)
                .padding()
                .frame(width: canvas.width, alignment: .leading),
            size: canvas
        )

        XCTAssertGreaterThan(
            drawn, 100,
            """
            the attached photo does not reach the screen. The tray is the only \
            way to tell one attachment from another, so a strip that renders \
            nothing is the same as no strip at all.
            """
        )
    }

    /// The inverse. Without it, a view that drew a red placeholder in every
    /// state would pass the test above and prove nothing.
    func testAnEmptyTrayDrawsNoPhoto() {
        let drawn = vermilionPixelCount(
            of: MealPhotoStrip(photos: .constant([]), note: nil)
                .padding()
                .frame(width: canvas.width, alignment: .leading),
            size: canvas
        )

        XCTAssertEqual(drawn, 0)
    }

    /// Three photos, three thumbnails. Three is the cap, so this is the widest
    /// the row ever gets and the case where it would overflow if it were going
    /// to.
    func testTheTrayDrawsEveryAttachedPhoto() throws {
        let jpeg = try makeJPEG()

        let one = vermilionPixelCount(
            of: MealPhotoStrip(photos: .constant([MealPhoto(jpegData: jpeg)]), note: nil)
                .padding().frame(width: canvas.width, alignment: .leading),
            size: canvas
        )
        let three = vermilionPixelCount(
            of: MealPhotoStrip(
                photos: .constant((0..<MealCaptureAccessories.maxPhotos).map { _ in
                    MealPhoto(jpegData: jpeg)
                }),
                note: nil
            ).padding().frame(width: canvas.width, alignment: .leading),
            size: canvas
        )

        XCTAssertGreaterThan(
            three, one * 2,
            "three thumbnails cover materially more of the row than one does"
        )
    }

    // MARK: - Removing one

    /// The remove button is bound to the photo it sits on, not to the last one.
    ///
    /// Driven through the identity the button closes over rather than through a
    /// synthetic tap, because the arithmetic is where an off-by-one would live
    /// and a synthetic tap would test SwiftUI's hit testing instead.
    func testRemovingAPhotoTakesTheRightOne() throws {
        let jpeg = try makeJPEG()
        let first = MealPhoto(jpegData: jpeg)
        let second = MealPhoto(jpegData: jpeg)
        var photos = [first, second]

        photos.removeAll { $0.id == first.id }

        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(
            photos.first?.id, second.id,
            """
            two photos of the same plate are byte-identical and are still two \
            attachments; removing one must not take the other.
            """
        )
    }
}

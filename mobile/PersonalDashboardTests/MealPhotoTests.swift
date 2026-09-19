import XCTest
import UIKit
@testable import PersonalDashboard

/// Turning a picker's bytes into something the Messages API will accept (#627).
///
/// The failure this guards against is specific and it fails LATE: a photo
/// library hands back HEIC on any recent iPhone, Anthropic accepts JPEG, PNG,
/// GIF and WebP and nothing else, and a raw 12-megapixel frame is several times
/// the base64 ceiling. Send either one and the error arrives as an HTTP 400 from
/// Anthropic, after the user has waited, with a message about a request body.
@MainActor
final class MealPhotoTests: XCTestCase {

    /// A photograph-sized image, big enough that the compressor has to do real
    /// work rather than pass the bytes through.
    private func makePNG(width: CGFloat = 3000, height: CGFloat = 2000) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { ctx in
            UIColor(red: 0.85, green: 0.78, blue: 0.62, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor(red: 0.62, green: 0.20, blue: 0.14, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(
                x: width * 0.25, y: height * 0.2,
                width: width * 0.5, height: height * 0.6
            ))
        }
        return try XCTUnwrap(image.pngData(), "the fixture encodes as PNG")
    }

    /// PNG in, JPEG out. The media type this announces has to be the truth about
    /// the bytes beside it, or the request is a lie Anthropic catches.
    func testAPNGComesBackAsActualJPEGBytes() async throws {
        let photo = try await MealPhoto.make(from: try makePNG())

        XCTAssertEqual(photo.mediaType, "image/jpeg")
        // SOI marker. Checked on the bytes rather than trusting `mediaType`,
        // which is a constant and would agree with itself no matter what the
        // compressor returned.
        XCTAssertEqual(
            Array(photo.jpegData.prefix(2)), [0xFF, 0xD8],
            "the bytes start with a JPEG SOI marker, not a PNG signature"
        )
    }

    /// The ceiling is Anthropic's, and base64 inflates by about a third.
    func testAFullSizePhotoIsBroughtUnderTheAPICeiling() async throws {
        let raw = try makePNG(width: 4032, height: 3024)
        let photo = try await MealPhoto.make(from: raw)

        XCTAssertLessThan(
            photo.jpegData.count, raw.count,
            "the whole point of the pass is that the bytes get smaller"
        )
        // 5 MB base64 / 1.34 ≈ 3.73 MB raw. `ReceiptStorage` targets 3.5 MB.
        XCTAssertLessThan(
            photo.jpegData.count, 3_500_000,
            "a full-frame photo fits under the base64 cap with margin"
        )
        XCTAssertGreaterThan(
            photo.jpegData.count, 1_000,
            "it is compressed, not emptied"
        )
    }

    /// Two photos of the same plate are two attachments, not one. The id is what
    /// the tray removes by, so a shared id would make one tap clear both.
    func testEachPhotoIsItsOwnAttachment() async throws {
        let raw = try makePNG(width: 800, height: 600)
        let first = try await MealPhoto.make(from: raw)
        let second = try await MealPhoto.make(from: raw)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(
            first.jpegData, second.jpegData,
            "identical input compresses identically; only the identity differs"
        )
    }

    /// Bytes that are not an image at all must fail here, where the composer can
    /// say so, rather than at the API.
    func testGarbageBytesFailBeforeTheyAreSent() async {
        let notAnImage = Data("this is not a photograph".utf8)

        do {
            _ = try await MealPhoto.make(from: notAnImage)
            XCTFail("undecodable bytes must not become a MealPhoto")
        } catch {
            // Any error is correct here. What matters is that it is thrown on
            // this side of the network call.
        }
    }
}

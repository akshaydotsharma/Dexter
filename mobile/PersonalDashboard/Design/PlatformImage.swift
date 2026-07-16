import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Module-wide platform image alias + small bridges, so shared code that has to
/// touch a concrete bitmap type (barcode render/decode, ticket ingest) keeps one
/// call shape across iOS and macOS instead of `#if` islands at every use.
///
/// Added for the native macOS target (issue #281). This is the general-purpose
/// sibling of Finance's `ReceiptPlatformImage`; both resolve to the same
/// underlying `UIImage` / `NSImage`, so the two aliases are interchangeable.
#if canImport(UIKit)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif

extension Image {
    /// Build a SwiftUI `Image` from the platform-native bitmap, cross-platform.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// The backing `CGImage`, cross-platform. `UIImage.cgImage` on iOS; the
    /// `cgImage(forProposedRect:…)` accessor on macOS (`NSImage` has no direct
    /// `cgImage` property). Nil for vector-only / undecodable images.
    var cgImageCompat: CGImage? {
        #if canImport(UIKit)
        return cgImage
        #else
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    /// JPEG-encode at `quality` (0…1), cross-platform. `UIImage.jpegData` on
    /// iOS; an `NSBitmapImageRep` round-trip on macOS.
    func jpegDataCompat(quality: CGFloat) -> Data? {
        #if canImport(UIKit)
        return jpegData(compressionQuality: quality)
        #else
        guard let cg = cgImageCompat else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #endif
    }
}

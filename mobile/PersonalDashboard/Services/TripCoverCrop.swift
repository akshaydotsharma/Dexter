import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Crops a generated illustration down to the tile's band, anchored on the
/// skyline's base (#428).
///
/// ## Why this exists at all
///
/// The prompt tells the model, emphatically, to keep the whole skyline inside the
/// bottom quarter and to let nothing approach the top edge. It does not reliably
/// obey. So the crop has to be robust to artwork nobody has inspected, which means
/// finding the silhouette rather than trusting the composition.
///
/// ## Three approaches, only the third works
///
/// 1. **Centre on the art's midpoint.** The skyline floats, leaving dead space
///    between its base and the seam divider. Wrong.
/// 2. **Anchor to the lowest non-background pixel.** That finds the bottom of the
///    *water*, not the base of the buildings, so the dead space survives AND the
///    towers clip at the top instead. Worse than (1).
/// 3. **Anchor to the silhouette.** A row that crosses buildings changes colour many
///    times across the width; sky and open water are nearly uniform. Counting those
///    transitions per row finds where the silhouette genuinely begins and ends.
///
/// (1) and (2) are recorded here so nobody re-derives them.
///
/// ## The rule
///
/// Sample the background from a corner. Count near-background/not-near-background
/// transitions per row. Rows with `minTransitions` or more carry real silhouette
/// detail; the first and last such rows are the silhouette's top and base. If the
/// silhouette plus a 4% pad fits the band, crop bottom-anchored to the base plus
/// that pad, so the skyline rises out of the divider with sky above it. If it does
/// not fit, SCALE the strip to the band rather than clipping it — losing the top of
/// a tower is far more visible than a few percent of vertical compression on flat
/// geometric shapes.
///
/// Runs once at cache time, never on render, so a bad crop is inspectable rather
/// than intermittent.
///
/// Pure ImageIO + CoreGraphics, so it needs no UIKit or AppKit shim and runs off the
/// main actor on both platforms.
enum TripCoverCrop {

    /// Which branch the crop took. Reported so a bad result is diagnosable without
    /// re-running the pipeline.
    enum Path: String {
        case anchored
        case scaled
    }

    struct Result {
        /// PNG bytes. PNG rather than JPEG because the caller hands this straight to
        /// `ReceiptStorage.compress`, which re-encodes to JPEG anyway; keeping this
        /// step lossless means the flat colour fields are not double-quantised.
        let imageData: Data
        let path: Path
        /// Vertical scale applied to the silhouette. 1.0 on the anchored path.
        let scale: Double
        let silhouetteTop: Int
        let silhouetteBase: Int
        let bandHeight: Int
        let sourceWidth: Int
        let sourceHeight: Int

        var summary: String {
            switch path {
            case .anchored:
                return "anchored (silhouette \(silhouetteBase - silhouetteTop)px in \(bandHeight)px band)"
            case .scaled:
                return String(
                    format: "scaled to %.0f%% (silhouette %dpx in %dpx band)",
                    scale * 100, silhouetteBase - silhouetteTop, bandHeight
                )
            }
        }
    }

    // MARK: - Tuning

    /// The band's proportion. 1536 wide gives a 384px band.
    static let bandRatio: Double = 4.0
    /// Per-channel tolerance for "this pixel is the background".
    static let backgroundTolerance = 26
    /// Transitions a row needs to count as the skyline's MASS. Sky and open water are
    /// near-uniform and score 0 to 2; a row of buildings scores many more. This is
    /// what finds the groundline, and it is the threshold that makes the base robust
    /// against a wide flat band of water being mistaken for content.
    static let minTransitions = 6

    /// Transitions a row needs to count as the silhouette's TOP.
    ///
    /// Lower than `minTransitions`, deliberately, and this is a correction to the
    /// reference implementation rather than a preference. A single spire crossing a
    /// row scores exactly 2 — one edge in, one edge out — so the 6-transition
    /// threshold that correctly finds the *base* silently excludes every narrow
    /// feature standing above the main mass. Measured on live output: it discarded
    /// 124 px above Hong Kong's detected top and 106 px above Pune's, which clipped
    /// the Bank of China Tower's antennae and cut Pune's clock tower flat against the
    /// frame edge. Italy happened to be unaffected, which is exactly how a bug like
    /// this survives review.
    ///
    /// Using a different threshold at each end is the point: each signal is used where
    /// it is reliable. "Lowest non-background pixel" is wrong for the BASE, because it
    /// finds the bottom of the water — that was rejected approach (2). It is right for
    /// the TOP, because there is no water above a skyline, only spires that must not be
    /// clipped. 2 rather than 1 so a single stray artefact pixel touching the image
    /// edge cannot pass for a tower.
    ///
    /// This also makes the anchored path's no-clipping guarantee real rather than
    /// vacuous. `silhouetteHeight + pad <= bandHeight` rearranges to
    /// `base + pad - bandHeight <= top`, i.e. the crop window always opens at or above
    /// the silhouette's top — but only if `top` is the true top. It was not.
    static let minTopTransitions = 2
    /// Horizontal sampling stride. Deliberately dense: at a coarser stride a narrow
    /// spire stops registering, and a spire is exactly what must not be clipped.
    static let horizontalStride = 3
    /// Breathing room under the silhouette's base, as a fraction of band height.
    static let padFraction: Double = 0.04

    // MARK: - Entry point

    static func crop(_ data: Data) -> Result? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return crop(image)
    }

    static func crop(_ image: CGImage) -> Result? {
        let width = image.width
        let height = image.height
        guard width > 8, height > 8 else { return nil }
        guard let bitmap = Bitmap(image) else { return nil }

        let bandHeight = Int(Double(width) / bandRatio)
        guard bandHeight > 0 else { return nil }
        // Degenerate source shorter than the band it has to fill: nothing sensible to
        // crop, so the caller falls back to generated glyph art.
        guard bandHeight <= height else { return nil }

        // Corner sample, a few pixels in so a stray edge artefact does not become
        // "the background colour".
        let background = bitmap.pixel(4, 4)

        // Two thresholds, one scan. The base is the last row carrying the skyline's
        // MASS; the top is the first row carrying any real object at all, so a lone
        // spire above the mass is included rather than cropped off.
        var silhouetteTop: Int?
        var silhouetteBase: Int?
        for y in 0..<height {
            let count = bitmap.transitions(row: y, background: background)
            if count >= minTopTransitions, silhouetteTop == nil { silhouetteTop = y }
            if count >= minTransitions { silhouetteBase = y }
        }
        // The BASE is what decides whether this is a skyline at all. A blank image, or
        // one holding nothing but a single flat block of water, has no row reaching
        // `minTransitions` and is reported as a failure so the caller draws the glyph
        // art and re-rolls, rather than cropping an empty band.
        guard let base = silhouetteBase else { return nil }
        // Clamped to the base so a stray artefact BELOW the groundline cannot invert
        // the pair.
        let top = min(silhouetteTop ?? base, base)

        let silhouetteHeight = base - top
        let pad = Int(Double(bandHeight) * padFraction)

        if silhouetteHeight + pad <= bandHeight {
            // Fits: bottom-anchor on the base so the skyline sits on the seam.
            //
            // The clamp is a robustness fix over the reference implementation, which
            // can compute a window running past the bottom edge when the silhouette
            // reaches the last row (`base + pad - bandHeight + bandHeight > height`).
            let rawTop = base + pad - bandHeight
            let cropTop = min(max(0, rawTop), max(0, height - bandHeight))
            guard let cropped = image.cropping(
                to: CGRect(x: 0, y: cropTop, width: width, height: bandHeight)
            ), let png = encodePNG(cropped) else { return nil }

            return Result(
                imageData: png, path: .anchored, scale: 1.0,
                silhouetteTop: top, silhouetteBase: base, bandHeight: bandHeight,
                sourceWidth: width, sourceHeight: height
            )
        }

        // Too tall: scale the strip, never clip it.
        let stripHeight = base + 1 - top
        let targetHeight = bandHeight - pad
        guard targetHeight > 0,
              let strip = image.cropping(
                to: CGRect(x: 0, y: top, width: width, height: stripHeight)
              ),
              let composited = compositeScaled(
                strip: strip, width: width, bandHeight: bandHeight,
                targetHeight: targetHeight, background: background
              ),
              let png = encodePNG(composited) else { return nil }

        return Result(
            imageData: png, path: .scaled,
            scale: Double(targetHeight) / Double(stripHeight),
            silhouetteTop: top, silhouetteBase: base, bandHeight: bandHeight,
            sourceWidth: width, sourceHeight: height
        )
    }

    // MARK: - Compositing

    /// Draw `strip` scaled to `targetHeight` at the TOP of a `bandHeight` canvas
    /// filled with the sampled background, leaving the pad below it. Matches the
    /// reference implementation's `paste(strip, (0, 0))`.
    private static func compositeScaled(
        strip: CGImage, width: Int, bandHeight: Int,
        targetHeight: Int, background: Bitmap.Pixel
    ) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: bandHeight, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        ctx.setFillColor(
            red: CGFloat(background.r) / 255,
            green: CGFloat(background.g) / 255,
            blue: CGFloat(background.b) / 255,
            alpha: 1
        )
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: bandHeight))
        ctx.interpolationQuality = .high
        // CGContext user space has its origin bottom-left, so the strip occupying the
        // TOP of the output is the rect from `pad` up to `bandHeight`.
        ctx.draw(
            strip,
            in: CGRect(
                x: 0, y: bandHeight - targetHeight,
                width: width, height: targetHeight
            )
        )
        return ctx.makeImage()
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: - Bitmap access

extension TripCoverCrop {

    /// A decoded RGB bitmap with top-down row indexing.
    ///
    /// Row 0 is the image's TOP row. A `CGBitmapContext`'s memory is stored top-down
    /// even though its user space has a bottom-left origin, so a plain `draw` needs no
    /// flip to get that. This is asserted by a unit test rather than trusted, because
    /// getting it backwards would anchor the crop on the sky and be plausible-looking
    /// in code.
    struct Bitmap {
        struct Pixel { let r: UInt8; let g: UInt8; let b: UInt8 }

        let width: Int
        let height: Int
        private let bytesPerRow: Int
        private let bytesPerPixel = 4
        private let pixels: [UInt8]

        init?(_ image: CGImage) {
            let width = image.width
            let height = image.height
            guard width > 0, height > 0 else { return nil }

            let bytesPerRow = width * 4
            var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
            let space = CGColorSpaceCreateDeviceRGB()

            let made: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(
                    data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else { return false }
                // Fill white first so a source with transparency resolves to the
                // off-white the prompt asks for rather than to black, which would read
                // as silhouette everywhere and break the transition count.
                ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard made else { return nil }

            self.width = width
            self.height = height
            self.bytesPerRow = bytesPerRow
            self.pixels = buffer
        }

        func pixel(_ x: Int, _ y: Int) -> Pixel {
            let clampedX = min(max(0, x), width - 1)
            let clampedY = min(max(0, y), height - 1)
            let i = clampedY * bytesPerRow + clampedX * bytesPerPixel
            return Pixel(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2])
        }

        /// Count near-background/not-near-background flips across one row.
        func transitions(row y: Int, background: Pixel) -> Int {
            var count = 0
            var previous: Bool?
            var x = 0
            while x < width {
                let isBackground = near(pixel(x, y), background)
                if let previous, previous != isBackground { count += 1 }
                previous = isBackground
                x += TripCoverCrop.horizontalStride
            }
            return count
        }

        private func near(_ a: Pixel, _ b: Pixel) -> Bool {
            let tol = TripCoverCrop.backgroundTolerance
            return abs(Int(a.r) - Int(b.r)) < tol
                && abs(Int(a.g) - Int(b.g)) < tol
                && abs(Int(a.b) - Int(b.b)) < tol
        }
    }
}

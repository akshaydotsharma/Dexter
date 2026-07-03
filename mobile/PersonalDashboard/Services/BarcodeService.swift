import Foundation
import UIKit
import Vision
import CoreImage
import PDFKit

/// Normalised symbology id stored on `LocalItineraryItem.barcodeSymbology`.
/// We persist a small stable token (not the raw `VNBarcodeSymbology.rawValue`,
/// which is verbose and version-coupled) so the scan screen knows which
/// CoreImage generator re-renders the code. `.other` covers symbologies we can
/// decode but not regenerate (EAN, UPC, DataMatrix, …); those fall back to the
/// original attachment on the scan screen.
enum BarcodeSymbology: String {
    case qr
    case aztec
    case pdf417
    case code128
    case other

    /// Map a Vision symbology to our normalised token.
    init(vision: VNBarcodeSymbology) {
        switch vision {
        case .qr:       self = .qr
        case .aztec:    self = .aztec
        case .pdf417:   self = .pdf417
        case .code128:  self = .code128
        default:        self = .other
        }
    }
}

/// One decoded barcode: the payload, its normalised symbology, and the
/// normalised bounding box (Vision's coordinate space: origin bottom-left,
/// 0…1 on each axis). The bounding box is NOT persisted — it's only used at
/// scan time to crop the original attachment when we can't regenerate the code.
struct DecodedBarcode {
    let payload: String
    let symbology: BarcodeSymbology
    /// Normalised, bottom-left-origin rect from Vision.
    let boundingBox: CGRect
}

/// On-device barcode decode + render. First-party frameworks only (Vision +
/// CoreImage + PDFKit); no third-party dependencies (#222).
///
/// Two responsibilities:
///  - `decode(...)`: find the most prominent barcode in an image (or a PDF's
///    rendered pages) and return its payload + symbology + bounding box.
///  - `render(...)`: regenerate a crisp barcode image from a stored payload in
///    its original symbology, scaled with nearest-neighbour so the modules stay
///    hard-edged (a smoothed barcode fails scanners).
enum BarcodeService {

    // MARK: - Decode

    /// Detect the single most prominent barcode in `image`. Returns `nil` when
    /// no barcode is found. When several are present we prefer the one with the
    /// largest bounding-box area (the primary ticket code, not a tiny promo QR).
    static func decode(image: UIImage) -> DecodedBarcode? {
        guard let cgImage = image.cgImage else { return nil }
        return decode(cgImage: cgImage, orientation: cgOrientation(from: image.imageOrientation))
    }

    /// Decode across a PDF's pages, returning the first page's most prominent
    /// barcode. Boarding-pass PDFs put the code on page 1, so we stop at the
    /// first hit rather than rasterising the whole document.
    static func decode(pdfData: Data, maxPages: Int = 3) -> DecodedBarcode? {
        guard let doc = PDFDocument(data: pdfData) else { return nil }
        let pages = min(doc.pageCount, maxPages)
        for index in 0..<pages {
            guard let page = doc.page(at: index) else { continue }
            let image = render(pdfPage: page, targetLongEdge: 2400)
            if let cg = image?.cgImage, let hit = decode(cgImage: cg, orientation: .up) {
                return hit
            }
        }
        return nil
    }

    private static func decode(cgImage: CGImage, orientation: CGImagePropertyOrientation) -> DecodedBarcode? {
        let request = VNDetectBarcodesRequest()
        // Restrict to the symbologies we actually surface, when available —
        // fewer symbologies means faster, less ambiguous detection. Guard the
        // property set so an OS that lacks one of these doesn't crash.
        request.symbologies = [.qr, .aztec, .pdf417, .code128, .ean13, .ean8, .code39, .dataMatrix]

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("BarcodeService: Vision decode failed: %@", error.localizedDescription)
            return nil
        }

        let observations = (request.results ?? [])
            .filter { $0.payloadStringValue?.isEmpty == false }

        // Prefer the largest code by bounding-box area.
        guard let best = observations.max(by: { areaOf($0.boundingBox) < areaOf($1.boundingBox) }),
              let payload = best.payloadStringValue else {
            return nil
        }
        return DecodedBarcode(
            payload: payload,
            symbology: BarcodeSymbology(vision: best.symbology),
            boundingBox: best.boundingBox
        )
    }

    private static func areaOf(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    // MARK: - Render (regenerate a crisp barcode)

    private static let ciContext = CIContext(options: nil)

    /// Regenerate a scannable barcode from a stored payload + symbology, sized
    /// so its longest edge is about `targetLongEdge` points, with hard-edged
    /// (nearest-neighbour) scaling. Returns `nil` for `.other`/unsupported
    /// symbologies or on any generation failure — the caller then falls back to
    /// the original attachment.
    static func render(payload: String, symbology: BarcodeSymbology, targetLongEdge: CGFloat = 900) -> UIImage? {
        guard !payload.isEmpty else { return nil }
        // Boarding-pass payloads are Latin-1; fall back to UTF-8 for QR URLs.
        let messageData = payload.data(using: .isoLatin1) ?? payload.data(using: .utf8)
        guard let messageData else { return nil }

        let filterName: String
        switch symbology {
        case .qr:       filterName = "CIQRCodeGenerator"
        case .aztec:    filterName = "CIAztecCodeGenerator"
        case .pdf417:   filterName = "CIPDF417BarcodeGenerator"
        case .code128:  filterName = "CICode128BarcodeGenerator"
        case .other:    return nil
        }

        guard let filter = CIFilter(name: filterName) else { return nil }
        filter.setValue(messageData, forKey: "inputMessage")
        // Higher error correction for the 2D codes so a slightly dim/curved
        // screen still scans. Ignored by the 1D Code128 generator.
        switch symbology {
        case .qr:    filter.setValue("M", forKey: "inputCorrectionLevel")
        case .aztec: filter.setValue(NSNumber(value: 23), forKey: "inputCorrectionLevel")
        default:     break
        }

        guard let output = filter.outputImage else { return nil }
        // Rasterise at the generator's native module size first, then upscale
        // with interpolation disabled so the modules stay razor-sharp.
        let extent = output.extent
        guard extent.width > 0, extent.height > 0,
              let nativeCG = ciContext.createCGImage(output, from: extent) else {
            return nil
        }
        return upscale(cgImage: nativeCG, targetLongEdge: targetLongEdge)
    }

    /// Draw a small generated code into a larger bitmap with nearest-neighbour
    /// sampling (no blur). Preserves aspect ratio (PDF417 is very wide). We draw
    /// via `UIImage.draw(in:)` rather than `CGContext.draw` so the code renders
    /// upright — a manual CG flip would MIRROR the code (fatal for QR/PDF417).
    private static func upscale(cgImage: CGImage, targetLongEdge: CGFloat) -> UIImage {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let scale = max(targetLongEdge / max(w, h), 1)
        let size = CGSize(width: w * scale, height: h * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            ctx.cgContext.interpolationQuality = .none
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - PDF rasterisation

    /// Render a single PDF page to a UIImage whose longest edge is about
    /// `targetLongEdge` points. Used for barcode decoding (needs detail) and
    /// for the one-shot extraction image (so we never depend on the PDF beta
    /// header). White-backed so a transparent page doesn't decode as black.
    static func render(pdfPage page: PDFPage, targetLongEdge: CGFloat) -> UIImage? {
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }
        let scale = max(targetLongEdge / max(pageRect.width, pageRect.height), 1)
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            // PDFKit draws in PDF (bottom-left origin) space; flip + scale.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
            page.draw(with: .mediaBox, to: cg)
        }
    }

    /// Convenience: render the first page of a PDF's data. Nil when the data
    /// isn't a readable PDF.
    static func renderFirstPage(pdfData: Data, targetLongEdge: CGFloat = 2000) -> UIImage? {
        guard let doc = PDFDocument(data: pdfData), let page = doc.page(at: 0) else { return nil }
        return render(pdfPage: page, targetLongEdge: targetLongEdge)
    }

    // MARK: - Helpers

    /// Crop `image` to a Vision-normalised bounding box (bottom-left origin),
    /// with a little padding so the quiet zone around the code is preserved.
    /// Returns the original image if the crop can't be computed.
    static func crop(image: UIImage, toNormalized box: CGRect, padding: CGFloat = 0.06) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        // Vision origin is bottom-left; CGImage crop origin is top-left.
        let padded = box.insetBy(dx: -padding, dy: -padding)
        let clamped = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return image }
        let rect = CGRect(
            x: clamped.origin.x * w,
            y: (1 - clamped.origin.y - clamped.height) * h,
            width: clamped.width * w,
            height: clamped.height * h
        )
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func cgOrientation(from ui: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch ui {
        case .up:            return .up
        case .down:          return .down
        case .left:          return .left
        case .right:         return .right
        case .upMirrored:    return .upMirrored
        case .downMirrored:  return .downMirrored
        case .leftMirrored:  return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }
}

import Foundation
#if canImport(UIKit)
import UIKit
#else
// macOS: the ticket encode/downsize path is built on ImageIO +
// CoreGraphics (portable, no UIKit), mirroring `ReceiptStorage`'s macOS branch.
// `UniformTypeIdentifiers` supplies the JPEG type identifier for the ImageIO
// destination. Added for the native macOS target (issue #281).
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#endif

/// Errors thrown by TicketStorage. Surface to the user when a save / delete
/// can't complete (rare: disk full, sandbox sealed, etc.).
enum TicketStorageError: LocalizedError {
    case imageEncodingFailed
    case fileSystem(Error)

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:  return "Couldn't encode the ticket image."
        case .fileSystem(let err):  return err.localizedDescription
        }
    }
}

/// File-system store for wallet-style ticket assets (#222). Writes go into
/// `Documents/tickets/<uuid>.<ext>` and only the relative path
/// (`"tickets/<uuid>.<ext>"`) is persisted onto `LocalItineraryItem.attachmentPath`.
///
/// Deliberately a near-clone of `ReceiptStorage` (same relative-path rationale,
/// same JPEG normalisation for Vision safety) rather than a shared base: the
/// two feature areas evolve independently and a tickets/ directory keeps the
/// asset namespaces from colliding. The image compression pipeline downsizes to
/// a longest edge that keeps the base64 payload well under Anthropic's 5 MB
/// per-image limit, so the SAME compressed bytes are safe for both the on-disk
/// save AND the barcode-decode / extraction passes.
///
/// Cross-platform (issue #281): iOS keeps the UIKit `UIImage` compression path
/// byte-for-byte; macOS uses the exact ImageIO + CoreGraphics approach already
/// proven in `ReceiptStorage` (decode → EXIF-transform → downsample →
/// JPEG-encode, off the main actor, no AppKit round-trip).
@MainActor
final class TicketStorage {
    static let shared = TicketStorage()

    private let fileManager: FileManager
    private let directoryName = "tickets"
    private let jpegQuality: CGFloat = 0.8
    /// Longest-edge cap. Tickets carry fine barcode detail (PDF417 rows), so we
    /// keep more resolution than receipts (2000 vs 1600) while staying under
    /// Anthropic's base64 cap and Vision's decode needs.
    private let targetMaxEdge: CGFloat = 2000
    /// Hard ceiling on raw JPEG bytes after compression (stays under Anthropic's
    /// 5 MB base64 cap with margin: 5 MB / 1.34 ≈ 3.73 MB raw).
    private let targetMaxBytes: Int = 3_500_000
    private let fallbackJpegQuality: CGFloat = 0.55

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Public API

    /// Compress raw image data (HEIC, PNG, oversized JPEG) into a JPEG that's
    /// safe to send to Anthropic Vision and to store on disk. Always downsizes
    /// to `targetMaxEdge` first. `nonisolated` so callers can run it off the
    /// main actor via `Task.detached` (the decode + re-encode is the expensive
    /// step) — it touches only immutable value constants.
    #if canImport(UIKit)
    nonisolated func compress(imageData: Data) throws -> Data {
        guard let image = UIImage(data: imageData) else {
            throw TicketStorageError.imageEncodingFailed
        }
        let resized = image.downsizedForTicket(longestEdge: targetMaxEdge) ?? image
        guard let firstPass = resized.jpegData(compressionQuality: jpegQuality) else {
            throw TicketStorageError.imageEncodingFailed
        }
        if firstPass.count <= targetMaxBytes { return firstPass }
        if let secondPass = resized.jpegData(compressionQuality: fallbackJpegQuality),
           secondPass.count <= targetMaxBytes {
            return secondPass
        }
        if let further = resized.downsizedForTicket(longestEdge: 1400),
           let thirdPass = further.jpegData(compressionQuality: fallbackJpegQuality) {
            return thirdPass
        }
        return firstPass
    }
    #else
    /// macOS counterpart to the UIKit `compress`. Same contract (downsize to
    /// `targetMaxEdge`, JPEG-encode, tighten quality / dimensions until under
    /// `targetMaxBytes`), built on ImageIO so it needs no AppKit `NSImage`
    /// round-trip and bakes in EXIF orientation. `nonisolated` for the same
    /// off-main-actor reason as iOS. Issue #281.
    nonisolated func compress(imageData: Data) throws -> Data {
        guard let firstPass = Self.downsampledJPEG(
            from: imageData, longestEdge: targetMaxEdge, quality: jpegQuality
        ) else {
            throw TicketStorageError.imageEncodingFailed
        }
        if firstPass.count <= targetMaxBytes { return firstPass }
        if let secondPass = Self.downsampledJPEG(
            from: imageData, longestEdge: targetMaxEdge, quality: fallbackJpegQuality
        ), secondPass.count <= targetMaxBytes {
            return secondPass
        }
        if let thirdPass = Self.downsampledJPEG(
            from: imageData, longestEdge: 1400, quality: fallbackJpegQuality
        ) {
            return thirdPass
        }
        return firstPass
    }
    #endif

    /// Persist a pre-compressed JPEG (typically the output of `compress`).
    /// Returned path is relative.
    func saveCompressedJpeg(_ data: Data) throws -> String {
        try persist(data: data, ext: "jpg")
    }

    /// Save raw PDF data unchanged. Returned path is relative.
    func save(pdfData: Data) throws -> String {
        try persist(data: pdfData, ext: "pdf")
    }

    /// Resolve a stored relative path back to an on-disk URL. Returns nil if the
    /// file no longer exists (e.g. user reinstalled the app).
    func load(relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              let url = try? absoluteURL(for: relativePath),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// Delete the file at `relativePath`. Silent no-op if the file is already
    /// gone — callers don't need to special-case a missing attachment.
    func delete(relativePath: String) throws {
        guard !relativePath.isEmpty else { return }
        let url = try absoluteURL(for: relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw TicketStorageError.fileSystem(error)
        }
    }

    /// True when a stored path points at a PDF (drives viewer branching).
    static func isPDF(_ relativePath: String) -> Bool {
        relativePath.lowercased().hasSuffix(".pdf")
    }

    // MARK: - Internals

    private func persist(data: Data, ext: String) throws -> String {
        let dir = try ensureDirectory()
        let filename = "\(UUID().uuidString.lowercased()).\(ext)"
        let url = dir.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw TicketStorageError.fileSystem(error)
        }
        return "\(directoryName)/\(filename)"
    }

    private func ensureDirectory() throws -> URL {
        let docs = try documentsDirectory()
        let dir = docs.appendingPathComponent(directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw TicketStorageError.fileSystem(error)
            }
        }
        return dir
    }

    private func documentsDirectory() throws -> URL {
        do {
            return try fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw TicketStorageError.fileSystem(error)
        }
    }

    private func absoluteURL(for relativePath: String) throws -> URL {
        let docs = try documentsDirectory()
        return docs.appendingPathComponent(relativePath)
    }
}

// MARK: - UIImage downsize helper

#if canImport(UIKit)
private extension UIImage {
    /// Resize so the longest edge is at most `longestEdge` points, preserving
    /// aspect ratio. Returns self when already small enough; nil only for a
    /// degenerate source. Named distinctly from ReceiptStorage's helper to
    /// avoid a duplicate-symbol collision in the same module.
    func downsizedForTicket(longestEdge: CGFloat) -> UIImage? {
        let width = size.width
        let height = size.height
        let maxSide = max(width, height)
        guard maxSide > longestEdge, maxSide > 0 else { return self }

        let scale = longestEdge / maxSide
        let newSize = CGSize(width: floor(width * scale), height: floor(height * scale))
        guard newSize.width > 0, newSize.height > 0 else { return nil }

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
#else

// MARK: - macOS ImageIO downsample + JPEG encode (issue #281)

private extension TicketStorage {
    /// Decode `data`, downsize so the longest edge is at most `longestEdge`
    /// pixels (never upscales, matching the iOS `downsizedForTicket` behaviour),
    /// bake in EXIF orientation, and re-encode as JPEG at `quality`. Pure
    /// ImageIO + CoreGraphics, so it runs off the main actor and needs no
    /// AppKit. Mirrors `ReceiptStorage.downsampledJPEG`.
    nonisolated static func downsampledJPEG(
        from data: Data, longestEdge: CGFloat, quality: CGFloat
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Apply the source's EXIF orientation to the pixels so a portrait
            // photo isn't stored sideways.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longestEdge.rounded()),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbOptions as CFDictionary
        ) else { return nil }

        let output = NSMutableData()
        let type = UTType.jpeg.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(
            output, type, 1, nil
        ) else { return nil }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
#endif

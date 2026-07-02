import Foundation
import UIKit

/// Errors thrown by ReceiptStorage. Surface to the user when a save / delete
/// can't complete (rare: disk full, sandbox sealed, etc.).
enum ReceiptStorageError: LocalizedError {
    case imageEncodingFailed
    case fileSystem(Error)

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:  return "Couldn't encode the receipt image."
        case .fileSystem(let err):  return err.localizedDescription
        }
    }
}

/// File-system store for receipt assets. Writes go into
/// `Documents/receipts/<uuid>.<ext>` and only the relative path
/// (`"receipts/<uuid>.<ext>"`) is persisted onto `LocalExpense.receiptImagePath`.
///
/// Why relative: the absolute container path changes on every app reinstall
/// and across simulator runs, so the stored path would break unless we
/// re-resolve against the Documents directory at read time. The trade-off
/// is one `appendingPathComponent` per read; cheap.
///
/// All captured images are normalised to a single compressed JPEG that is
/// safe for both on-disk storage and Anthropic Vision. The compressed bytes
/// are returned by `compress(imageData:)` so callers can hand the same blob
/// to Vision and to the disk save — avoids the bug where the disk got a
/// compressed copy but Vision got the original raw HEIC (which blew past
/// Anthropic's 5 MB base64 limit).
@MainActor
final class ReceiptStorage {
    static let shared = ReceiptStorage()

    private let fileManager: FileManager
    private let directoryName = "receipts"
    private let jpegQuality: CGFloat = 0.75
    /// Longest-edge cap applied to every captured image. 1600 px is more than
    /// enough resolution for receipt OCR via Anthropic Vision and keeps the
    /// base64 payload well under Anthropic's 5 MB-per-image limit (which is
    /// measured on the base64 string, not the raw bytes — ~33% inflation).
    private let targetMaxEdge: CGFloat = 1600
    /// Hard ceiling on raw JPEG bytes after compression. Stays under
    /// Anthropic's 5 MB base64 cap with margin (5 MB / 1.34 ≈ 3.73 MB raw).
    private let targetMaxBytes: Int = 3_500_000
    /// JPEG quality used when the first pass still exceeds `targetMaxBytes`.
    /// Receipts stay legible at this level.
    private let fallbackJpegQuality: CGFloat = 0.5

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Public API

    /// Compress raw image data (HEIC, PNG, oversized JPEG, whatever) into a
    /// JPEG that's safe to send to Anthropic Vision. ALWAYS downsizes to
    /// `targetMaxEdge` first — captured camera photos are way overkill for
    /// receipt OCR and the original byte-count routinely exceeds the API
    /// cap. Use the returned data for BOTH the Vision call AND the disk save.
    ///
    /// `nonisolated` so callers can run it off the main actor (via
    /// `Task.detached`): the decode + downsize + JPEG re-encode is the
    /// expensive step, and keeping it off main lets the Finance "Processing"
    /// row render immediately rather than after compression finishes (#200
    /// follow-up). It reads only immutable value-typed constants and touches
    /// no actor-isolated state, so it's safe to call from any executor.
    nonisolated func compress(imageData: Data) throws -> Data {
        guard let image = UIImage(data: imageData) else {
            throw ReceiptStorageError.imageEncodingFailed
        }
        let resized = image.downsized(longestEdge: targetMaxEdge) ?? image
        guard let firstPass = resized.jpegData(compressionQuality: jpegQuality) else {
            throw ReceiptStorageError.imageEncodingFailed
        }
        if firstPass.count <= targetMaxBytes {
            return firstPass
        }
        if let secondPass = resized.jpegData(compressionQuality: fallbackJpegQuality),
           secondPass.count <= targetMaxBytes {
            return secondPass
        }
        // Last resort: more aggressive downsize and quality drop combined.
        if let further = resized.downsized(longestEdge: 1024),
           let thirdPass = further.jpegData(compressionQuality: fallbackJpegQuality) {
            return thirdPass
        }
        return firstPass
    }

    /// Persist a pre-compressed JPEG (typically the output of `compress(imageData:)`).
    /// Returned path is relative.
    func saveCompressedJpeg(_ data: Data) throws -> String {
        try persist(data: data, ext: "jpg")
    }

    /// Legacy convenience: compress + save in one shot. Kept for callers that
    /// don't need the compressed bytes (e.g. failure paths that just need
    /// the receipt on disk and don't call Vision).
    func save(imageData: Data, fileExtension: String) throws -> String {
        _ = fileExtension // Kept for API parity; output is always .jpg.
        let compressed = try compress(imageData: imageData)
        return try persist(data: compressed, ext: "jpg")
    }

    /// Save raw PDF data unchanged. Returned path is relative.
    func save(pdfData: Data) throws -> String {
        try persist(data: pdfData, ext: "pdf")
    }

    /// Restore a previously-exported receipt at its original relative path.
    /// Used by the data importer to put receipts back in
    /// `Documents/receipts/<uuid>.<ext>` without picking a new filename.
    /// Returns the same `relativePath` it was given so callers can store it
    /// directly onto `LocalExpense.receiptImagePath`.
    @discardableResult
    func write(data: Data, relativePath: String) throws -> String {
        _ = try ensureDirectory()
        let url: URL
        do {
            url = try absoluteURL(for: relativePath)
        } catch {
            throw ReceiptStorageError.fileSystem(error)
        }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ReceiptStorageError.fileSystem(error)
        }
        return relativePath
    }

    /// Resolve a stored relative path back to an on-disk URL. Returns nil if
    /// the file no longer exists (e.g. user reinstalled the app).
    func load(relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              let url = try? absoluteURL(for: relativePath),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// Delete the file at `relativePath`. Silent no-op if the file is
    /// already gone — callers don't need to special-case missing receipts.
    func delete(relativePath: String) throws {
        guard !relativePath.isEmpty else { return }
        let url = try absoluteURL(for: relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw ReceiptStorageError.fileSystem(error)
        }
    }

    // MARK: - Internals

    private func persist(data: Data, ext: String) throws -> String {
        let dir = try ensureDirectory()
        let filename = "\(UUID().uuidString.lowercased()).\(ext)"
        let url = dir.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ReceiptStorageError.fileSystem(error)
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
                throw ReceiptStorageError.fileSystem(error)
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
            throw ReceiptStorageError.fileSystem(error)
        }
    }

    private func absoluteURL(for relativePath: String) throws -> URL {
        let docs = try documentsDirectory()
        return docs.appendingPathComponent(relativePath)
    }
}

// MARK: - UIImage downsize helper

private extension UIImage {
    /// Resize so the longest edge is at most `longestEdge` points, preserving
    /// aspect ratio. Returns nil if the source is degenerate.
    func downsized(longestEdge: CGFloat) -> UIImage? {
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

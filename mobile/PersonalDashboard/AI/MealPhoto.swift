import Foundation

/// A photograph of a meal, held only for as long as it takes to estimate it
/// (#627).
///
/// ### Why it is a value type and not a stored asset
///
/// Every other image in this app is kept: a receipt backs an expense, a ticket
/// backs a trip, a note photo is the note. A meal photo is none of those. It is
/// an INPUT, the same kind of thing the description field holds, and the
/// estimate is the output it produces. Once the numbers are on the row the photo
/// has said everything it had to say.
///
/// Keeping it anyway would not be free. A stored photo needs a field on
/// `LocalMeal`, a directory under `Documents`, an entry in the sealed sync
/// manifests, a line in `DataArchive.exportedModels`, an orphan sweep, and a
/// delete path on every surface that can remove a meal. That is five subsystems
/// bought for a thumbnail nobody asked to keep. The decision was taken
/// deliberately on #627 and is the reason this type holds `Data` rather than a
/// relative path.
///
/// So the lifetime is exactly the composer's: it lives in `@State`, it is sent
/// with the estimate, and it is dropped by the same `reset()` that clears the
/// description field.
struct MealPhoto: Identifiable, Sendable, Equatable {

    let id: UUID

    /// Compressed JPEG bytes, already downsized for the Messages API.
    ///
    /// Always JPEG, never the picker's own bytes. A photo library hands back
    /// HEIC on any recent iPhone, and the Messages API accepts JPEG, PNG, GIF
    /// and WebP and nothing else — so the raw blob would be rejected by the API
    /// rather than by anything here, which is the worst place to find out.
    let jpegData: Data

    var mediaType: String { "image/jpeg" }

    var base64: String { jpegData.base64EncodedString() }

    init(id: UUID = UUID(), jpegData: Data) {
        self.id = id
        self.jpegData = jpegData
    }

    /// Normalise raw picker bytes into something the API will accept.
    ///
    /// Routed through `ReceiptStorage.compress(imageData:)` rather than a
    /// compressor of its own: that function already decodes HEIC, bakes in EXIF
    /// orientation, downsizes to the longest edge and tightens quality until the
    /// bytes fit under Anthropic's base64 ceiling, and it does it on both
    /// platforms. A second implementation here would be a second answer to a
    /// question that has one.
    ///
    /// The decode and re-encode is the expensive step, so it runs off the main
    /// actor the way every other call site of that function does. The instance
    /// is captured on the main actor first because `ReceiptStorage.shared` is
    /// main-actor isolated; `compress` itself is `nonisolated`.
    ///
    /// Nothing is written to disk. `ReceiptStorage` is used here purely as a
    /// compressor, which is why this calls `compress` and never `save`.
    @MainActor
    static func make(from raw: Data) async throws -> MealPhoto {
        let storage = ReceiptStorage.shared
        let compressed = try await Task.detached(priority: .userInitiated) {
            try storage.compress(imageData: raw)
        }.value
        return MealPhoto(jpegData: compressed)
    }
}

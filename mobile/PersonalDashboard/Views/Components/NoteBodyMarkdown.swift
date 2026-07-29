import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Inline note images: the bridge between the markdown a note stores and the
/// attributed text the editors show (#395, reshaped so images sit at the point
/// in the writing where they were pasted rather than in a separate section).
///
/// ## The representation
///
/// A note's `content` stays plain markdown. An image is one token:
///
///     ![](note-images/9f2c….jpg)
///
/// which is exactly the relative path already persisted on `LocalNoteImage`. The
/// token is the single source of truth for POSITION; the model rows remain the
/// inventory (what to pack into the export, what to delete when the note goes).
///
/// ## Why a bijection matters
///
/// `attributed(from:)` turns each token into exactly ONE attachment character,
/// and `markdown(from:)` turns each attachment character back into exactly that
/// token. One character in, one token out, nothing added: the user's own
/// newlines around an image round-trip untouched. Anything else and every open
/// of a note would quietly rewrite its body, which sync sees as an edit.
enum NoteBodyMarkdown {

    /// Matches `![alt](path)` where the path points into our own image
    /// directory. Scoped to `note-images/` on purpose so a normal markdown image
    /// link to a remote URL in someone's note is left alone as text.
    private static let pattern = #"!\[([^\]]*)\]\((note-images/[^)\s]+)\)"#

    private static let regex: NSRegularExpression = {
        // The pattern is a compile-time constant, so a throw here is a
        // programmer error rather than anything a user can cause.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Every image path referenced by `markdown`, in the order it appears.
    ///
    /// Used to reconcile the rows against the text: an image the user deleted
    /// out of the body no longer appears here, which is what lets its row and
    /// file be cleaned up.
    static func referencedPaths(in markdown: String) -> [String] {
        let ns = markdown as NSString
        return regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                guard match.numberOfRanges > 2 else { return nil }
                return ns.substring(with: match.range(at: 2))
            }
    }

    /// Wrap a relative path as the markdown token for it.
    static func token(for relativePath: String) -> String {
        "![](\(relativePath))"
    }

    /// Split `markdown` into the alternating text and image runs a renderer
    /// needs. Text segments keep their exact substring so offsets stay honest.
    enum Segment: Hashable {
        case text(String)
        case image(path: String, alt: String)
    }

    static func segments(in markdown: String) -> [Segment] {
        let ns = markdown as NSString
        var out: [Segment] = []
        var cursor = 0
        for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                out.append(.text(ns.substring(with: NSRange(
                    location: cursor, length: match.range.location - cursor
                ))))
            }
            let alt = match.numberOfRanges > 1 ? ns.substring(with: match.range(at: 1)) : ""
            let path = match.numberOfRanges > 2 ? ns.substring(with: match.range(at: 2)) : ""
            out.append(.image(path: path, alt: alt))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            out.append(.text(ns.substring(from: cursor)))
        }
        return out
    }

    // MARK: - Editor conversion

    /// Build the attributed string an editor displays: body text in `font` /
    /// `color`, and one `InlineImageAttachment` per image token.
    ///
    /// An image whose file is not on this device still becomes an attachment, so
    /// the token never leaks into the writing surface as raw markdown. The
    /// attachment draws a "missing" placeholder instead — see
    /// `InlineImageAttachment`.
    static func attributed(
        from markdown: String,
        font: PlatformFont,
        color: PlatformColor,
        resolve: (String) -> URL?
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        for segment in segments(in: markdown) {
            switch segment {
            case .text(let string):
                out.append(NSAttributedString(string: string, attributes: base))
            case .image(let path, let alt):
                let attachment = InlineImageAttachment(
                    relativePath: path, alt: alt, fileURL: resolve(path)
                )
                let attributed = NSMutableAttributedString(attachment: attachment)
                // Keep the base font on the attachment character. Without it the
                // line height around an image collapses to the system default and
                // text typed straight after the image comes out in the wrong font.
                attributed.addAttributes(base, range: NSRange(location: 0, length: attributed.length))
                out.append(attributed)
            }
        }
        return out
    }

    /// Serialise an editor's attributed string back to markdown, turning every
    /// `InlineImageAttachment` back into its token.
    ///
    /// Attachments we did not create are dropped rather than guessed at: the only
    /// way one appears is a paste of rich content we have not converted, and
    /// emitting a token for a file we never saved would leave a permanently
    /// broken reference in the note.
    static func markdown(from attributed: NSAttributedString) -> String {
        let ns = attributed.string as NSString
        var out = ""
        var cursor = 0
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, range, _ in
            guard let attachment = value else { return }
            if range.location > cursor {
                out += ns.substring(with: NSRange(
                    location: cursor, length: range.location - cursor
                ))
            }
            if let inline = attachment as? InlineImageAttachment {
                out += token(for: inline.relativePath)
            }
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            out += ns.substring(from: cursor)
        }
        return out
    }
}

// MARK: - Platform aliases

#if canImport(UIKit)
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#elseif canImport(AppKit)
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#endif

// MARK: - InlineImageAttachment

/// A note image sitting inline in an editor's text.
///
/// Carries the relative path so serialisation back to markdown is exact rather
/// than reverse-engineered from the image bytes. Sizing is computed at layout
/// time from the line fragment it is being placed into, which is what makes an
/// image reflow when the window or keyboard changes the text width instead of
/// staying pinned to whatever width existed when the note was opened.
final class InlineImageAttachment: NSTextAttachment {
    let relativePath: String
    let alt: String
    /// Longest edge an inline image is drawn at, so one photo doesn't push the
    /// rest of the note off the screen.
    private let maxHeight: CGFloat = 260

    init(relativePath: String, alt: String, fileURL: URL?) {
        self.relativePath = relativePath
        self.alt = alt
        super.init(data: nil, ofType: nil)
        if let fileURL, let loaded = PlatformImage(contentsOfFile: fileURL.path) {
            self.image = loaded
        } else {
            self.image = Self.missingPlaceholder()
        }
    }

    required init?(coder: NSCoder) {
        self.relativePath = ""
        self.alt = ""
        super.init(coder: coder)
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return CGRect(x: 0, y: 0, width: 0, height: 0)
        }
        // Never wider than the text column, never taller than `maxHeight`.
        let available = max(lineFrag.width, 1)
        let scale = min(available / image.size.width, maxHeight / image.size.height, 1)
        return CGRect(
            x: 0, y: 0,
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
    }

    /// Drawn in place of an image whose bytes are not on this device (synced
    /// from the other client, or lost to a reinstall). A visible tile rather
    /// than nothing, so the note still shows that something belongs there.
    private static func missingPlaceholder() -> PlatformImage? {
        let size = CGSize(width: 240, height: 120)
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.secondarySystemFill.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = "Image on your other device"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.secondaryLabel
            ]
            let bounds = (text as NSString).boundingRect(
                with: size, options: .usesLineFragmentOrigin, attributes: attrs, context: nil
            )
            (text as NSString).draw(
                at: CGPoint(x: (size.width - bounds.width) / 2,
                            y: (size.height - bounds.height) / 2),
                withAttributes: attrs
            )
        }
        #elseif canImport(AppKit)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        let text = "Image on your other device"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let bounds = (text as NSString).boundingRect(
            with: size, options: .usesLineFragmentOrigin, attributes: attrs
        )
        (text as NSString).draw(
            at: CGPoint(x: (size.width - bounds.width) / 2,
                        y: (size.height - bounds.height) / 2),
            withAttributes: attrs
        )
        image.unlockFocus()
        return image
        #else
        return nil
        #endif
    }
}

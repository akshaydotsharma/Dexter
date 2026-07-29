import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - MarkdownEditor
//
// SwiftUI wrapper around UITextView that exposes selection so a format
// toolbar can wrap the selected range (or insert at cursor) with markdown
// syntax. The toolbar lives in the textView's `inputAccessoryView`, so it
// rides above the keyboard automatically and disappears when editing ends.
//
// Why UITextView and not SwiftUI's TextEditor: pre-iOS 18 SwiftUI doesn't
// expose selection, so we can't wrap the selected range from a button tap.
// UITextView gives us `selectedRange`, key-input behavior, and an obvious
// place to attach the input accessory view.

#if os(iOS)
struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    var minHeight: CGFloat = 320
    var placeholder: String = ""
    /// Persist pasted image bytes and return the relative path to reference
    /// (#395). Nil means the image could not be saved, and nothing is inserted.
    /// Absent for editors that are not note bodies, which then reject image
    /// pastes rather than inserting a reference to a file nobody wrote.
    var saveImage: ((Data) async -> String?)? = nil

    func makeUIView(context: Context) -> PaddedTextView {
        let tv = PaddedTextView()
        tv.delegate = context.coordinator
        tv.font = UIFont(name: "Inter-Regular", size: 16) ?? UIFont.systemFont(ofSize: 16)
        tv.textColor = UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? 0xF2EBDA : 0x1F1B16))
        }
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.alwaysBounceVertical = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.autocorrectionType = .yes
        tv.autocapitalizationType = .sentences
        tv.dataDetectorTypes = []

        // Build and own the format toolbar so its weak reference back to the
        // textView never dangles. Coordinator owns the wrapper view.
        let toolbar = MarkdownFormatToolbarView()
        toolbar.textViewProvider = { [weak tv] in tv }
        toolbar.onChange = { [weak tv] in
            guard let tv else { return }
            // `noteMarkdown`, not `.text`: the display string carries U+FFFC
            // object-replacement characters where images sit, which is not what
            // the note stores (#395).
            context.coordinator.parent.text = tv.noteMarkdown
        }
        toolbar.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44)
        toolbar.autoresizingMask = .flexibleWidth
        tv.inputAccessoryView = toolbar
        context.coordinator.toolbar = toolbar

        // Placeholder support
        tv.placeholderText = placeholder

        // Inline images (#395). Render the stored markdown as attributed text so
        // pictures appear in the writing surface where they were placed, then let
        // a paste add one at the cursor.
        tv.setNoteMarkdown(text)
        tv.saveImage = saveImage
        // Declare images acceptable, which is what makes UIKit route a dropped or
        // pasted image through `paste(itemProviders:)`. Without it the drop is
        // offered as text and lands as a file path.
        if saveImage != nil {
            tv.pasteConfiguration = UIPasteConfiguration(
                acceptableTypeIdentifiers: [
                    "public.image", "public.png", "public.jpeg", "public.heic", "public.text"
                ]
            )
        }
        tv.onImageInserted = { [weak tv] in
            guard let tv else { return }
            context.coordinator.parent.text = tv.noteMarkdown
            tv.refreshPlaceholder()
            tv.invalidateIntrinsicContentSize()
        }

        return tv
    }

    func updateUIView(_ uiView: PaddedTextView, context: Context) {
        uiView.saveImage = saveImage
        // Compare against the SERIALISED markdown, not `uiView.text` (#395).
        // The display string holds a single U+FFFC per image where the markdown
        // holds a whole `![](note-images/…)` token, so comparing the two would
        // never match on a note containing an image and this would reload and
        // reset the cursor on every SwiftUI pass.
        if uiView.noteMarkdown != text {
            // Preserve cursor position across SwiftUI-driven re-renders.
            let savedRange = uiView.selectedRange
            uiView.setNoteMarkdown(text)
            let safeLocation = min(savedRange.location, (uiView.text as NSString).length)
            uiView.selectedRange = NSRange(location: safeLocation, length: 0)
            uiView.refreshPlaceholder()
            uiView.invalidateIntrinsicContentSize()
        }
        if uiView.placeholderText != placeholder {
            uiView.placeholderText = placeholder
            uiView.refreshPlaceholder()
        }
        if isFocused, !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        }
    }

    /// SwiftUI hands us the proposed width here. Without this, UITextView with
    /// `isScrollEnabled = false` reports its intrinsic size based on a layout
    /// that hasn't been width-constrained yet and the text spills off-screen
    /// as one infinite line. We measure with the proposed width so the
    /// textView wraps and only then ask SwiftUI for vertical space.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PaddedTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(measured.height, minHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditor
        weak var toolbar: MarkdownFormatToolbarView?

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.noteMarkdown
            (textView as? PaddedTextView)?.refreshPlaceholder()
        }

        /// Return-key list continuation. Pressing Return on a list line inserts
        /// the next marker (bullets repeat, numbers increment). Pressing Return
        /// on an empty list item removes the marker and exits the list.
        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            guard replacement == "\n" else { return true }
            let ns = textView.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            var line = ns.substring(with: lineRange)
            if line.hasSuffix("\n") { line.removeLast() }

            guard let marker = EditorListMarker(line: line) else { return true }

            let updated: String
            let cursor: Int
            if marker.content.trimmingCharacters(in: .whitespaces).isEmpty {
                // Empty item: strip the marker and drop out of the list.
                let markerRange = NSRange(location: lineRange.location,
                                          length: (marker.raw as NSString).length)
                updated = ns.replacingCharacters(in: markerRange, with: "")
                cursor = markerRange.location
            } else {
                // Continue the list with the next marker.
                let insertion = "\n" + marker.next
                updated = ns.replacingCharacters(in: range, with: insertion)
                cursor = range.location + (insertion as NSString).length
            }

            // `applyDisplayString` rather than `.text =`: assigning a plain String
            // discards every inline image attachment in the note (#395).
            textView.applyDisplayString(updated, selection: NSRange(location: cursor, length: 0))
            parent.text = textView.noteMarkdown
            (textView as? PaddedTextView)?.refreshPlaceholder()
            textView.invalidateIntrinsicContentSize()
            return false
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.isFocused = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.isFocused = false
            }
        }
    }
}

// MARK: - Inline image support (#395)

extension UITextView {

    /// Font + colour every run in a note body carries. Read off the view so the
    /// editor's own configuration stays the single source of truth.
    var noteBaseAttributes: [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [:]
        if let font { attrs[.font] = font }
        if let textColor { attrs[.foregroundColor] = textColor }
        return attrs
    }

    /// The note's markdown: the display text with every inline image attachment
    /// turned back into its `![](note-images/…)` token.
    var noteMarkdown: String {
        NoteBodyMarkdown.markdown(from: attributedText)
    }

    /// Replace the contents from stored markdown, building an attachment for
    /// each image token so pictures render in place while the user types.
    func setNoteMarkdown(_ markdown: String) {
        let resolved = NoteBodyMarkdown.attributed(
            from: markdown,
            font: font ?? UIFont.systemFont(ofSize: 16),
            color: textColor ?? .label,
            resolve: { ReceiptStorage.noteImages.load(relativePath: $0) }
        )
        attributedText = resolved
        typingAttributes = noteBaseAttributes
    }

    /// Inline image attachments, in document order.
    func inlineImageAttachments() -> [InlineImageAttachment] {
        var found: [InlineImageAttachment] = []
        attributedText.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: attributedText.length), options: []
        ) { value, _, _ in
            if let inline = value as? InlineImageAttachment { found.append(inline) }
        }
        return found
    }

    /// Swap in a whole new DISPLAY string while keeping inline image attachments.
    ///
    /// The formatting toolbar and the list-continuation logic both compute a
    /// complete replacement string from `text`, which is the pragmatic thing to do
    /// for plain markdown but drops every attachment when assigned back. They only
    /// ever add or remove markdown syntax around text, though: they never create
    /// or delete an attachment character. So the U+FFFC positions in `newDisplay`
    /// line up 1:1 and in order with the attachments already present, and
    /// re-threading them is exact rather than a guess.
    func applyDisplayString(_ newDisplay: String, selection: NSRange? = nil) {
        let attachments = inlineImageAttachments()
        let base = noteBaseAttributes
        let ns = newDisplay as NSString
        let rebuilt = NSMutableAttributedString()
        var runStart = 0
        var next = 0

        for index in 0..<ns.length where ns.character(at: index) == 0xFFFC {
            if index > runStart {
                rebuilt.append(NSAttributedString(
                    string: ns.substring(with: NSRange(location: runStart, length: index - runStart)),
                    attributes: base
                ))
            }
            if next < attachments.count {
                let piece = NSMutableAttributedString(attachment: attachments[next])
                piece.addAttributes(base, range: NSRange(location: 0, length: piece.length))
                rebuilt.append(piece)
                next += 1
            }
            runStart = index + 1
        }
        if runStart < ns.length {
            rebuilt.append(NSAttributedString(string: ns.substring(from: runStart), attributes: base))
        }

        let previous = selectedRange
        attributedText = rebuilt
        typingAttributes = base
        let target = selection ?? previous
        let clamped = min(target.location, rebuilt.length)
        selectedRange = NSRange(location: clamped, length: min(target.length, rebuilt.length - clamped))
    }
}

// MARK: - PaddedTextView
//
// UITextView with placeholder support (drawn via an embedded UILabel so it
// follows the same line metrics as the actual text).

final class PaddedTextView: UITextView {
    var placeholderText: String = "" {
        didSet { placeholderLabel.text = placeholderText }
    }

    /// Persists pasted image bytes and returns the relative path (#395).
    var saveImage: ((Data) async -> String?)? = nil
    /// Called after an image has been inserted, so the binding picks up the
    /// new markdown. `textViewDidChange` does not fire for programmatic edits.
    var onImageInserted: (() -> Void)? = nil

    private var lastBoundsWidth: CGFloat = 0

    private let placeholderLabel: UILabel = {
        let l = UILabel()
        l.numberOfLines = 0
        l.textColor = UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? 0x756B5B : 0xA89E8A))
        }
        l.font = UIFont(name: "Inter-Regular", size: 16) ?? UIFont.systemFont(ofSize: 16)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshPlaceholder),
            name: UITextView.textDidChangeNotification,
            object: self
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    /// With `isScrollEnabled = false`, UITextView's intrinsicContentSize is
    /// what SwiftUI uses to lay us out vertically. We measure against our
    /// current bounds.width so the textView wraps to the column SwiftUI gave
    /// us instead of trying to fit every line on one infinite-width row.
    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }
        let measured = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: measured.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastBoundsWidth {
            lastBoundsWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    @objc func refreshPlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty
        invalidateIntrinsicContentSize()
    }

    // MARK: - Image paste (#395)

    /// Offer Paste when the pasteboard holds an image, which UIKit does not do by
    /// default for a plain-text view.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), saveImage != nil, UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        // Text pastes keep UIKit's own behaviour, including its undo handling.
        guard saveImage != nil,
              UIPasteboard.general.hasImages,
              let data = Self.pasteboardImageData() else {
            super.paste(sender)
            return
        }
        insertImage(data: data)
    }

    /// Prefer the pasteboard's own bytes over re-encoding a `UIImage`.
    ///
    /// Screenshots arrive as PNG and photos as HEIC or JPEG; handing the original
    /// bytes to the compressor keeps one encode step instead of two, and avoids
    /// silently inflating a screenshot into a lossless re-encode.
    private static func pasteboardImageData() -> Data? {
        let board = UIPasteboard.general
        for type in ["public.png", "public.jpeg", "public.heic", "public.tiff"] {
            if let data = board.data(forPasteboardType: type) { return data }
        }
        return board.image?.pngData()
    }

    /// Drag-and-drop, and the paste of any non-text item.
    ///
    /// UIKit routes both through here once `pasteConfiguration` says we accept
    /// images. Without it a dragged image is offered as text and the drop lands in
    /// the note as a file path rather than a picture.
    override func paste(itemProviders: [NSItemProvider]) {
        let imageProviders = itemProviders.filter { $0.canLoadObject(ofClass: UIImage.self) }
        guard saveImage != nil, !imageProviders.isEmpty else {
            super.paste(itemProviders: itemProviders)
            return
        }
        Task { @MainActor in
            for provider in imageProviders {
                guard let data = await Self.imageData(from: provider) else { continue }
                await insertImageAwaiting(data: data)
            }
        }
    }

    /// Bytes for one dropped item, preferring the original file representation
    /// over a `UIImage` re-encode so a HEIC photo is not inflated on the way in.
    private static func imageData(from provider: NSItemProvider) async -> Data? {
        for identifier in ["public.png", "public.jpeg", "public.heic", "public.tiff"]
        where provider.hasItemConformingToTypeIdentifier(identifier) {
            let data: Data? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if let data { return data }
        }
        let image: UIImage? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
        return image?.pngData()
    }

    /// Save the bytes, then splice an attachment in at the cursor.
    ///
    /// Insertion happens after the await, so the range is re-read at that point:
    /// the user can keep typing while a large photo compresses, and the image
    /// must land where the cursor is NOW rather than where it was when they
    /// pressed Paste.
    func insertImage(data: Data) {
        Task { @MainActor in await insertImageAwaiting(data: data) }
    }

    @MainActor
    func insertImageAwaiting(data: Data) async {
        guard let saveImage else { return }
        guard let relativePath = await saveImage(data) else { return }

        // Caret read AFTER the await: compressing a photo takes long enough for
        // the user to keep typing, and a batch of dropped images has to land in
        // order rather than all at the original cursor.
        let requested = selectedRange
        let attachment = InlineImageAttachment(
            relativePath: relativePath,
            alt: "",
            fileURL: ReceiptStorage.noteImages.load(relativePath: relativePath)
        )
        let piece = NSMutableAttributedString(attachment: attachment)
        piece.addAttributes(
            noteBaseAttributes, range: NSRange(location: 0, length: piece.length)
        )

        let storage = NSMutableAttributedString(attributedString: attributedText)
        let target = NSRange(location: min(requested.location, storage.length), length: 0)
        storage.replaceCharacters(in: target, with: piece)
        attributedText = storage
        typingAttributes = noteBaseAttributes
        selectedRange = NSRange(location: target.location + piece.length, length: 0)
        onImageInserted?()
    }
}

// MARK: - MarkdownFormatToolbarView
//
// Horizontal scroll of format buttons placed above the keyboard via
// `inputAccessoryView`. Mutates the bound text via the editor's coordinator
// so SwiftUI sees the change and the rendered preview stays in sync.

final class MarkdownFormatToolbarView: UIView {
    /// Provides the live textView (weak) so we can read & mutate text/selection.
    var textViewProvider: (() -> UITextView?)? = nil
    /// Called after each successful mutation so the SwiftUI binding updates.
    var onChange: (() -> Void)? = nil

    private let stack = UIStackView()
    private let scrollView = UIScrollView()
    private let separator = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? 0x1B1813 : 0xF4F0E6))
        }

        separator.backgroundColor = UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? 0x2A2620 : 0xEFE9DA))
        }
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -12),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])

        buildButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    private func buildButtons() {
        let actions: [(String, String, () -> Void)] = [
            ("bold", "B",
                { [weak self] in self?.wrapInline("**") }),
            ("italic", "I",
                { [weak self] in self?.wrapInline("*") }),
            ("heading", "H",
                { [weak self] in self?.cycleHeading() }),
            ("bullet", "•",
                { [weak self] in self?.prefixLines("- ") }),
            ("numbered", "1.",
                { [weak self] in self?.numberLines() }),
            ("quote", "❝",
                { [weak self] in self?.prefixLines("> ") }),
            ("code", "</>",
                { [weak self] in self?.wrapInline("`") }),
            ("link", "🔗",
                { [weak self] in self?.insertLink() }),
        ]

        for (id, title, handler) in actions {
            let button = makeButton(title: title, identifier: id, handler: handler)
            stack.addArrangedSubview(button)
        }

        // Keyboard-dismiss button at the trailing edge.
        let dismiss = UIButton(type: .system)
        dismiss.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        dismiss.tintColor = UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? 0xA89E8A : 0x7B7263))
        }
        dismiss.widthAnchor.constraint(equalToConstant: 36).isActive = true
        dismiss.heightAnchor.constraint(equalToConstant: 32).isActive = true
        dismiss.addAction(UIAction { [weak self] _ in
            self?.textViewProvider?()?.resignFirstResponder()
        }, for: .touchUpInside)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(dismiss)
    }

    private func makeButton(title: String, identifier: String, handler: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        config.background.cornerRadius = 8
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            // Bold in monospaced "code" button reads better with mono.
            if identifier == "code" {
                out.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
            } else if identifier == "bold" {
                out.font = UIFont.systemFont(ofSize: 16, weight: .bold)
            } else if identifier == "italic" {
                out.font = UIFont.italicSystemFont(ofSize: 16)
            } else if identifier == "numbered" {
                out.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
            } else {
                out.font = UIFont.systemFont(ofSize: 15, weight: .medium)
            }
            return out
        }

        let b = UIButton(configuration: config)
        b.tintColor = UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? 0xF2EBDA : 0x1F1B16))
        }
        b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        b.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        b.accessibilityLabel = identifier
        return b
    }

    // MARK: Mutations

    private func wrapInline(_ marker: String) {
        guard let tv = textViewProvider?() else { return }
        let ns = tv.text as NSString
        let range = tv.selectedRange

        if range.length == 0 {
            // No selection: insert the marker pair and put the cursor between
            // them so the next keystroke goes inside the wrapper.
            let insertion = "\(marker)\(marker)"
            let updated = ns.replacingCharacters(in: range, with: insertion)
            tv.applyDisplayString(updated)
            let cursor = range.location + (marker as NSString).length
            tv.selectedRange = NSRange(location: cursor, length: 0)
        } else {
            let selected = ns.substring(with: range)
            let wrapped = "\(marker)\(selected)\(marker)"
            let updated = ns.replacingCharacters(in: range, with: wrapped)
            tv.applyDisplayString(updated)
            tv.selectedRange = NSRange(
                location: range.location + (marker as NSString).length,
                length: range.length
            )
        }
        onChange?()
    }

    private func insertLink() {
        guard let tv = textViewProvider?() else { return }
        let ns = tv.text as NSString
        let range = tv.selectedRange
        let label = range.length > 0 ? ns.substring(with: range) : "label"
        let inserted = "[\(label)](url)"
        let updated = ns.replacingCharacters(in: range, with: inserted)
        tv.applyDisplayString(updated)
        // Select the "url" placeholder so the user can immediately type over it.
        let urlOffset = inserted.distance(from: inserted.startIndex, to: inserted.lastIndex(of: "(")!) + 1
        let urlLength = (inserted as NSString).length - urlOffset - 1
        tv.selectedRange = NSRange(location: range.location + urlOffset, length: urlLength)
        onChange?()
    }

    private func prefixLines(_ prefix: String) {
        guard let tv = textViewProvider?() else { return }
        let ns = tv.text as NSString
        let range = tv.selectedRange
        let lineRange = ns.lineRange(for: range)
        let chunk = ns.substring(with: lineRange)
        let lines = chunk.components(separatedBy: "\n")

        // Toggle: if every non-empty line already starts with this prefix,
        // strip it. Otherwise add it. Trailing-empty-line bookkeeping keeps
        // the blank line at the end intact when we hit a paragraph boundary.
        let nonEmptyLines = lines.enumerated().filter { idx, line in
            !(idx == lines.count - 1 && line.isEmpty)
        }.map { $0.element }
        let allPrefixed = !nonEmptyLines.isEmpty && nonEmptyLines.allSatisfy { $0.hasPrefix(prefix) }

        let newLines: [String] = lines.enumerated().map { idx, line in
            // Don't prefix the trailing empty line that lineRange leaves on
            // multi-line selections.
            if idx == lines.count - 1, line.isEmpty { return line }
            if allPrefixed {
                return String(line.dropFirst(prefix.count))
            } else {
                return prefix + line
            }
        }

        let replacement = newLines.joined(separator: "\n")
        let updated = ns.replacingCharacters(in: lineRange, with: replacement)
        tv.applyDisplayString(updated)
        let lengthDelta = (replacement as NSString).length - lineRange.length
        let newLocation = range.location + (allPrefixed ? -prefix.count : prefix.count)
        let safeLocation = max(0, min(newLocation, (updated as NSString).length))
        tv.selectedRange = NSRange(
            location: safeLocation,
            length: max(0, range.length + lengthDelta - (allPrefixed ? -prefix.count : prefix.count))
        )
        onChange?()
    }

    /// Numbers the selected lines sequentially (1., 2., 3.…). Re-tapping when
    /// every content line is already numbered strips the markers (toggle off).
    /// Unlike `prefixLines`, the marker is computed per line, so multi-digit
    /// markers (10., 11.) toggle off cleanly instead of dropping a fixed count.
    private func numberLines() {
        guard let tv = textViewProvider?() else { return }
        let ns = tv.text as NSString
        let range = tv.selectedRange
        let lineRange = ns.lineRange(for: range)
        let lines = ns.substring(with: lineRange).components(separatedBy: "\n")

        // lineRange leaves a trailing empty element on multi-line selections;
        // that isn't a list line.
        func isTrailingEmpty(_ idx: Int, _ line: String) -> Bool {
            idx == lines.count - 1 && line.isEmpty
        }
        let contentLines = lines.enumerated().filter { !isTrailingEmpty($0.offset, $0.element) }
        let allNumbered = !contentLines.isEmpty
            && contentLines.allSatisfy { orderedMarkerLength($0.element) != nil }

        var counter = 0
        let newLines: [String] = lines.enumerated().map { idx, line in
            if isTrailingEmpty(idx, line) { return line }
            if allNumbered {
                return String(line.dropFirst(orderedMarkerLength(line) ?? 0))
            }
            counter += 1
            return "\(counter). " + line
        }

        let replacement = newLines.joined(separator: "\n")
        let updated = ns.replacingCharacters(in: lineRange, with: replacement)
        tv.applyDisplayString(updated)
        let replacementNS = replacement as NSString
        if range.length == 0 {
            // Cursor only: collapse it at the end of the (now-numbered) line so
            // typing continues naturally.
            var end = lineRange.location + replacementNS.length
            if replacement.hasSuffix("\n") { end -= 1 }
            let safe = max(0, min(end, (updated as NSString).length))
            tv.selectedRange = NSRange(location: safe, length: 0)
        } else {
            // Keep the block selected so a second tap toggles the numbering off.
            tv.selectedRange = NSRange(location: lineRange.location, length: replacementNS.length)
        }
        onChange?()
    }

    /// Length of a leading ordered-list marker ("12. " -> 4), or nil if the
    /// line doesn't begin with one.
    private func orderedMarkerLength(_ line: String) -> Int? {
        var idx = line.startIndex
        var digits = 0
        while idx < line.endIndex, line[idx].isNumber, digits < 3 {
            digits += 1
            idx = line.index(after: idx)
        }
        guard digits >= 1, idx < line.endIndex, line[idx] == "." else { return nil }
        let after = line.index(after: idx)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return digits + 2
    }

    /// Cycles the heading level of the current line: none → `# ` → `## ` →
    /// `### ` → none. Operates on the line containing the cursor.
    private func cycleHeading() {
        guard let tv = textViewProvider?() else { return }
        let ns = tv.text as NSString
        let lineRange = ns.lineRange(for: tv.selectedRange)
        var line = ns.substring(with: lineRange)
        let trailingNewline = line.hasSuffix("\n")
        if trailingNewline { line.removeLast() }

        let stripped: String
        let nextPrefix: String
        if line.hasPrefix("### ") {
            stripped = String(line.dropFirst(4))
            nextPrefix = ""
        } else if line.hasPrefix("## ") {
            stripped = String(line.dropFirst(3))
            nextPrefix = "### "
        } else if line.hasPrefix("# ") {
            stripped = String(line.dropFirst(2))
            nextPrefix = "## "
        } else {
            stripped = line
            nextPrefix = "# "
        }

        let rebuilt = nextPrefix + stripped + (trailingNewline ? "\n" : "")
        let updated = ns.replacingCharacters(in: lineRange, with: rebuilt)
        tv.applyDisplayString(updated)
        let newCursor = lineRange.location + (rebuilt as NSString).length - (trailingNewline ? 1 : 0)
        let safeCursor = max(0, min(newCursor, (updated as NSString).length))
        tv.selectedRange = NSRange(location: safeCursor, length: 0)
        onChange?()
    }
}

// MARK: - EditorListMarker
//
// Parses a leading list marker on an editor line so the Return key can
// continue the list. Ordered markers carry their integer so the next line
// increments; unordered markers repeat their bullet character.

private struct EditorListMarker {
    private enum Kind {
        case unordered(Character)
        case ordered(Int)
    }

    private let kind: Kind
    /// The leading marker including its trailing space ("- " or "3. ").
    let raw: String
    /// The line text after the marker.
    let content: String

    init?(line: String) {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            kind = .unordered(bullet.first!)
            raw = bullet
            content = String(line.dropFirst(bullet.count))
            return
        }

        var idx = line.startIndex
        var digits = 0
        while idx < line.endIndex, line[idx].isNumber, digits < 3 {
            digits += 1
            idx = line.index(after: idx)
        }
        guard digits >= 1, idx < line.endIndex, line[idx] == "." else { return nil }
        let space = line.index(after: idx)
        guard space < line.endIndex, line[space] == " " else { return nil }
        guard let number = Int(line[line.startIndex..<idx]) else { return nil }
        kind = .ordered(number)
        raw = String(line[line.startIndex...space])
        content = String(line[line.index(after: space)...])
    }

    /// The marker that opens the next line.
    var next: String {
        switch kind {
        case .unordered(let char): return "\(char) "
        case .ordered(let number): return "\(number + 1). "
        }
    }
}
#else

// MARK: - macOS MarkdownEditor
//
// Native editor for the Mac port (issue #281). macOS has no software keyboard, so
// the iOS `inputAccessoryView` format toolbar has no analog; with a full hardware
// keyboard, typing markdown directly is the natural path. The preview tab renders
// via `MarkdownView`.
//
// Wraps `NSTextView` rather than SwiftUI's `TextEditor` (#395). `TextEditor` binds
// a plain `String` and cannot hold an `NSTextAttachment`, so inline images could
// not appear in the writing surface at all — the Mac would have shown raw
// `![](note-images/…)` tokens while iOS showed pictures. Everything else here
// keeps the previous behaviour: placeholder overlay, real focus, AppKit
// selection and scrolling, and the same init API so `NotesView` is unchanged.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    var minHeight: CGFloat = 320
    var placeholder: String = ""
    /// Persist pasted image bytes and return the relative path (#395).
    var saveImage: ((Data) async -> String?)? = nil

    func makeNSView(context: Context) -> NoteTextView {
        let tv = NoteTextView()
        tv.delegate = context.coordinator
        tv.font = NSFont(name: "Inter-Regular", size: 16) ?? NSFont.systemFont(ofSize: 16)
        tv.textColor = NSColor(Tokens.ink)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        // Grow with content; the enclosing SwiftUI ScrollView does the scrolling,
        // matching how the iOS side sets `isScrollEnabled = false`.
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.placeholderText = placeholder
        tv.saveImage = saveImage
        tv.setNoteMarkdown(text)
        tv.onImageInserted = { [weak tv] in
            guard let tv else { return }
            context.coordinator.parent.text = tv.noteMarkdown
        }
        return tv
    }

    func updateNSView(_ nsView: NoteTextView, context: Context) {
        context.coordinator.parent = self
        nsView.saveImage = saveImage
        nsView.placeholderText = placeholder
        // Same markdown-vs-display comparison as iOS: an image is one attachment
        // character on screen and a whole token in the note.
        if nsView.noteMarkdown != text {
            let saved = nsView.selectedRange()
            nsView.setNoteMarkdown(text)
            let length = (nsView.string as NSString).length
            nsView.setSelectedRange(NSRange(location: min(saved.location, length), length: 0))
        }
        if isFocused, nsView.window?.firstResponder !== nsView {
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NoteTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        nsView.frame.size.width = width
        nsView.textContainer?.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        guard let layout = nsView.layoutManager, let container = nsView.textContainer else {
            return CGSize(width: width, height: minHeight)
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        return CGSize(width: width, height: max(used, minHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NoteTextView else { return }
            parent.text = tv.noteMarkdown
            tv.refreshPlaceholder()
            tv.invalidateIntrinsicContentSize()
        }

        func textDidBeginEditing(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in self?.parent.isFocused = true }
        }

        func textDidEndEditing(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in self?.parent.isFocused = false }
        }
    }
}

// MARK: - NoteTextView (macOS)

/// `NSTextView` with a placeholder and image paste, the AppKit twin of
/// `PaddedTextView` (#395).
final class NoteTextView: NSTextView {
    var placeholderText: String = "" {
        didSet { needsDisplay = true }
    }
    var saveImage: ((Data) async -> String?)? = nil
    var onImageInserted: (() -> Void)? = nil

    override var intrinsicContentSize: NSSize {
        guard let layout = layoutManager, let container = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        layout.ensureLayout(for: container)
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: layout.usedRect(for: container).height
        )
    }

    func refreshPlaceholder() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderText.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor(Tokens.muted)
        ]
        (placeholderText as NSString).draw(
            in: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height),
            withAttributes: attrs
        )
    }

    // MARK: - Image paste and drop

    /// Advertise image and file types so AppKit offers them to us at all.
    ///
    /// Without this, a dragged file is only ever offered as a string and the drop
    /// lands in the note as a path.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        Self.imageTypes + [.fileURL] + super.readablePasteboardTypes
    }

    override func paste(_ sender: Any?) {
        guard saveImage != nil,
              let images = Self.imageData(from: .general), !images.isEmpty else {
            // `pasteAsPlainText` rather than `super.paste`: the view is
            // `isRichText = false`, and letting AppKit paste styled text into a
            // markdown body drags in fonts and colours the note cannot represent.
            pasteAsPlainText(sender)
            return
        }
        insertImages(images)
    }

    /// Drag-and-drop, and AppKit's own paste path, both funnel through here.
    ///
    /// This is the hook a DROP uses, and it hands over the dragging pasteboard
    /// rather than the general one — which is why reading `NSPasteboard.general`
    /// was never going to see a dragged image, and the drop fell through to
    /// AppKit inserting the file's path as text.
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        if saveImage != nil, let images = Self.imageData(from: pboard), !images.isEmpty {
            insertImages(images)
            return true
        }
        return super.readSelection(from: pboard)
    }

    override func readSelection(
        from pboard: NSPasteboard, type: NSPasteboard.PasteboardType
    ) -> Bool {
        if saveImage != nil, let images = Self.imageData(from: pboard), !images.isEmpty {
            insertImages(images)
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }

    /// Encodings we accept directly, most faithful first. Screenshots arrive as
    /// PNG, photos as HEIC or JPEG; TIFF is AppKit's lossless fallback and is last
    /// because it is the one macOS synthesises when nothing better was offered.
    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("public.png"),
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        .tiff
    ]

    /// Image bytes on `board`, preferring the original encoding over a re-encode.
    ///
    /// Handles both shapes a picture arrives in: raw bytes (copied out of Preview,
    /// a screenshot, a browser) and file references (dragged from Finder or
    /// Photos). File URLs are checked FIRST — a Finder drag carries both a
    /// `fileURL` and a TIFF preview, and the file is the real thing while the
    /// preview can be a downscaled thumbnail.
    ///
    /// Returns nil rather than an empty array when there is nothing image-shaped,
    /// so callers can tell "not an image, handle as text" from "no images found".
    private static func imageData(from board: NSPasteboard) -> [Data]? {
        var out: [Data] = []

        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                guard let data = try? Data(contentsOf: url),
                      NSImage(data: data) != nil else { continue }
                out.append(data)
            }
        }
        if out.isEmpty {
            for type in imageTypes {
                if let data = board.data(forType: type) {
                    out.append(data)
                    break
                }
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Insert a batch in order, each at the cursor left by the previous one.
    private func insertImages(_ payloads: [Data]) {
        Task { @MainActor in
            for data in payloads {
                await insertImageAwaiting(data: data)
            }
        }
    }

    func insertImage(data: Data) {
        Task { @MainActor in await insertImageAwaiting(data: data) }
    }

    /// Save the bytes, then splice an attachment in at the cursor.
    ///
    /// The range is re-read AFTER the await, so a batch of dropped images lands in
    /// order (each after the last) and a single image lands where the caret is now
    /// rather than where it was when the drop started.
    @MainActor
    func insertImageAwaiting(data: Data) async {
        guard let saveImage else { return }
        guard let relativePath = await saveImage(data) else { return }

        // Read the caret AFTER the await, not before. Compressing a photo takes
        // long enough for the user to keep typing, and for a batch of dropped
        // images each one has to land after the previous one.
        let requested = selectedRange()
        let attachment = InlineImageAttachment(
            relativePath: relativePath,
            alt: "",
            fileURL: ReceiptStorage.noteImages.load(relativePath: relativePath)
        )
        let piece = NSMutableAttributedString(attachment: attachment)
        var base: [NSAttributedString.Key: Any] = [:]
        if let font { base[.font] = font }
        if let textColor { base[.foregroundColor] = textColor }
        piece.addAttributes(base, range: NSRange(location: 0, length: piece.length))

        let storage = NSMutableAttributedString(attributedString: attributedString())
        let target = NSRange(location: min(requested.location, storage.length), length: 0)
        storage.replaceCharacters(in: target, with: piece)
        textStorage?.setAttributedString(storage)
        typingAttributes = base
        setSelectedRange(NSRange(location: target.location + piece.length, length: 0))
        onImageInserted?()
        refreshPlaceholder()
        invalidateIntrinsicContentSize()
    }
}

// MARK: - Inline image support (macOS)

extension NSTextView {

    var noteMarkdown: String {
        NoteBodyMarkdown.markdown(from: attributedString())
    }

    func setNoteMarkdown(_ markdown: String) {
        let resolved = NoteBodyMarkdown.attributed(
            from: markdown,
            font: font ?? NSFont.systemFont(ofSize: 16),
            color: textColor ?? .labelColor,
            resolve: { ReceiptStorage.noteImages.load(relativePath: $0) }
        )
        textStorage?.setAttributedString(resolved)
        var base: [NSAttributedString.Key: Any] = [:]
        if let font { base[.font] = font }
        if let textColor { base[.foregroundColor] = textColor }
        typingAttributes = base
    }
}
#endif

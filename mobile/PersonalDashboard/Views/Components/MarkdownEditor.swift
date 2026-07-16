import SwiftUI
import UIKit

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

struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    var minHeight: CGFloat = 320
    var placeholder: String = ""

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
            context.coordinator.parent.text = tv.text
        }
        toolbar.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44)
        toolbar.autoresizingMask = .flexibleWidth
        tv.inputAccessoryView = toolbar
        context.coordinator.toolbar = toolbar

        // Placeholder support
        tv.placeholderText = placeholder

        return tv
    }

    func updateUIView(_ uiView: PaddedTextView, context: Context) {
        if uiView.text != text {
            // Preserve cursor position across SwiftUI-driven re-renders.
            let savedRange = uiView.selectedRange
            uiView.text = text
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
            parent.text = textView.text
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

            textView.text = updated
            textView.selectedRange = NSRange(location: cursor, length: 0)
            parent.text = updated
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

// MARK: - PaddedTextView
//
// UITextView with placeholder support (drawn via an embedded UILabel so it
// follows the same line metrics as the actual text).

final class PaddedTextView: UITextView {
    var placeholderText: String = "" {
        didSet { placeholderLabel.text = placeholderText }
    }

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
            tv.text = updated
            let cursor = range.location + (marker as NSString).length
            tv.selectedRange = NSRange(location: cursor, length: 0)
        } else {
            let selected = ns.substring(with: range)
            let wrapped = "\(marker)\(selected)\(marker)"
            let updated = ns.replacingCharacters(in: range, with: wrapped)
            tv.text = updated
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
        tv.text = updated
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
        tv.text = updated
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
        tv.text = updated
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
        tv.text = updated
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

import SwiftUI

#if os(macOS)
import AppKit

/// A borderless, fully transparent single-line text field for macOS inline
/// editing, used by the Tasks "New task" draft row and the task-title inline
/// rename (issue #287).
///
/// ## Why this exists (the field-editor grey box)
/// Every `NSTextField` in a window shares ONE field editor (an `NSTextView`)
/// that the window creates LAZILY and installs into a field only when that
/// field first becomes first responder. That shared field editor is what draws
/// the opaque grey control-background fill you see behind a focused SwiftUI
/// `TextField` — a SwiftUI `.background(.clear)` cannot reach it.
///
/// The earlier fix (`clearTextFieldBackgroundOnMac`) did a one-shot walk to the
/// enclosing field and cleared `currentEditor()` once. That worked for the
/// tap-to-edit path (the field settles into focus after the walk runs) but NOT
/// for the draft row, which AUTOFOCUSES on appear: the field becomes first
/// responder and the field editor is created AFTER the one-shot walk, so it was
/// never cleared and the grey box stayed.
///
/// `ClearBackgroundTextField` clears the live field editor inside
/// `becomeFirstResponder()`, so it runs EVERY time editing starts — after the
/// editor exists — and is robust for both the autofocusing draft field and the
/// tap-to-edit field.
///
/// The whole type is compiled out on iOS, where the SwiftUI `TextField` is kept
/// unchanged.
final class ClearBackgroundTextField: NSTextField {
    /// Desired focus state, pushed from SwiftUI via `updateNSView`.
    var wantsFocus = false

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let editor = currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            // Keep the caret clearly visible against the paper row.
            editor.insertionPointColor = NSColor(Tokens.ink)
        }
        return ok
    }

    /// The draft row autofocuses on appear: SwiftUI sets `wantsFocus` before the
    /// field is in a window, so the initial focus attempt would no-op. Retry
    /// once the field is attached to a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFocusIfNeeded()
    }

    /// Reconcile the AppKit first-responder state with `wantsFocus`. Only acts
    /// on a genuine transition — crucially, it NEVER re-issues
    /// `makeFirstResponder(self)` while the field is already being edited, which
    /// would tear down and restart the edit session (firing an end-editing
    /// commit after the first keystroke).
    func applyFocusIfNeeded() {
        guard let window = window else { return }
        let focused = isEditingNow
        if wantsFocus && !focused {
            window.makeFirstResponder(self)
        } else if !wantsFocus && focused {
            window.makeFirstResponder(nil)
        }
    }

    /// Authoritative "is this field currently being edited" check. When an
    /// `NSTextField` is edited, the window's first responder is the shared field
    /// editor (an `NSTextView`) whose `delegate` is this field — this holds even
    /// when `currentEditor()` is transiently nil during a SwiftUI update pass.
    var isEditingNow: Bool {
        guard let window = window else { return false }
        if window.firstResponder === self { return true }
        if let editor = window.firstResponder as? NSTextView, editor.delegate === self {
            return true
        }
        return false
    }
}

/// SwiftUI wrapper around `ClearBackgroundTextField`. Mirrors the behaviour of
/// the SwiftUI `TextField` it replaces on macOS: two-way text binding,
/// placeholder, programmatic focus (driven from the caller's `@FocusState`),
/// submit-on-Return, and commit-on-blur.
struct MacClearTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    /// Two-way focus flag bridged from the caller's `@FocusState`. When the
    /// caller flips it to `true` we make the field first responder; when the
    /// field loses focus we flip it back to `false`.
    @Binding var isFocused: Bool
    /// Return key.
    let onSubmit: () -> Void
    /// Fired whenever the field's editing focus changes; callers use the
    /// `false` edge to commit on blur.
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ClearBackgroundTextField {
        let field = ClearBackgroundTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.allowsEditingTextAttributes = false
        // Match TaskRowMetrics.titleFont on macOS (Inter-Regular 15) and the
        // Tokens.ink text colour so the field is visually identical to the
        // Text it toggles with.
        field.font = NSFont(name: "Inter-Regular", size: 15) ?? .systemFont(ofSize: 15)
        field.textColor = NSColor(Tokens.ink)
        field.placeholderString = placeholder
        field.stringValue = text
        if let cell = field.cell as? NSTextFieldCell {
            cell.drawsBackground = false
            cell.backgroundColor = .clear
            cell.isScrollable = true
            cell.wraps = false
        }
        // Let the field stretch to fill the row instead of hugging its text.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: ClearBackgroundTextField, context: Context) {
        // Keep the coordinator's closures/bindings fresh — SwiftUI rebuilds this
        // struct on every render, but the coordinator is created once.
        context.coordinator.parent = self
        // The field owns its text WHILE being edited; only sync the binding INTO
        // the field when it is not the first responder. Overwriting a live edit
        // from a (possibly stale) binding would clobber what the user is typing.
        if !field.isEditingNow, field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        field.wantsFocus = isFocused
        // Deferred a runloop tick so the window/hierarchy is settled (the draft
        // row is inserted and focused asynchronously by the caller).
        DispatchQueue.main.async { field.applyFocusIfNeeded() }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacClearTextField
        init(_ parent: MacClearTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) {
            // Propagate AppKit focus GAIN back into SwiftUI's focus flag. Without
            // this, a field focused by a mouse click (or a settled autofocus)
            // leaves `isFocused` false, so the very next `updateNSView` would see
            // `wantsFocus == false` while the field is editing and resign it —
            // firing a spurious commit after the first keystroke/paste.
            if !parent.isFocused { parent.isFocused = true }
        }

        // Deliberately NOT updating `parent.text` on every keystroke. Doing so
        // re-renders the parent `List` on each character, which tears down and
        // recreates this row's NSView mid-edit and fires a spurious end-editing
        // commit (committing only the first typed character). The field owns its
        // text during editing; the binding is synced on submit/blur only.

        func controlTextDidEndEditing(_ obj: Notification) {
            // Blur: push the field's final text into the binding, then report
            // focus loss so the caller can commit.
            if let field = obj.object as? NSTextField {
                if parent.text != field.stringValue { parent.text = field.stringValue }
            }
            if parent.isFocused { parent.isFocused = false }
            parent.onFocusChange(false)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                // Return: push current text into the binding, commit, then clear
                // the field so the draft can chain into the next new task. We
                // keep the field first responder (return true suppresses the
                // default end-editing).
                parent.text = textView.string
                parent.onSubmit()
                textView.string = ""
                control.stringValue = ""
                return true
            }
            return false
        }
    }
}
#endif

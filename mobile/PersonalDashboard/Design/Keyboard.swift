import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Keyboard dismiss helpers

extension View {
    /// Adds a transparent background tap that resigns the first responder.
    ///
    /// Used as a backstop on surfaces where tapping outside a `TextField` /
    /// `TextEditor` should dismiss the keyboard and bring the floating tab
    /// bar back into view (the bar hides while the keyboard is up — issue
    /// #48). Designed to be applied at the SURFACE ROOT so it only catches
    /// taps on empty background space; legitimate row taps and button taps
    /// inside the surface still win because `.background` sits behind the
    /// content's own hit-test area.
    ///
    /// Pair with `.scrollDismissesKeyboard(.interactively)` on the scroll
    /// container so users can also flick the keyboard down by dragging.
    func dismissKeyboardOnTap() -> some View {
        modifier(DismissKeyboardOnTapModifier())
    }

    /// Imperatively resigns the first responder, dismissing whatever `TextField`
    /// / `TextEditor` is currently focused. Callable from tap handlers on neutral
    /// chrome (headers, count strips, add bars) so tapping them commits an
    /// in-progress inline edit uniformly: every editable row and draft commits on
    /// focus loss via its own `.onChange(of:)`, so resigning first responder here
    /// routes through those commit paths without the parent needing per-row focus
    /// state. Wraps the same `sendAction` idiom used inline elsewhere.
    func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
        // macOS has no software keyboard; nothing to dismiss.
    }
}

private struct DismissKeyboardOnTapModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            // `.background` sits behind the content's own hit-test surface,
            // so live row taps and button taps still register. Only taps that
            // fall through to empty space hit this layer.
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        #if canImport(UIKit)
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                        #endif
                    }
            )
    }
}

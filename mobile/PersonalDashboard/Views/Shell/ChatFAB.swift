import SwiftUI
import UIKit

/// Floating Sparkles chip pinned bottom-right of every non-chat surface.
/// Tapping it pops back to the chat root. Hides itself while the keyboard
/// is visible so it never covers an in-row submit affordance.
struct ChatFAB: View {
    var action: () -> Void
    @State private var keyboardVisible = false

    var body: some View {
        ZStack {
            if !keyboardVisible {
                Button(action: action) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Tokens.paper)
                        .frame(width: 52, height: 52)
                        .background(Tokens.ink, in: Circle())
                        .shadowMd()
                }
                .accessibilityLabel("Open chat")
                .padding(.trailing, Space.lg)
                .padding(.bottom, Space.lg)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.18)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.18)) { keyboardVisible = false }
        }
    }
}

import SwiftUI

/// Floating Sparkles chip pinned bottom-right of every non-chat surface.
/// Tapping it pops back to the chat root.
struct ChatFAB: View {
    var action: () -> Void

    var body: some View {
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
    }
}

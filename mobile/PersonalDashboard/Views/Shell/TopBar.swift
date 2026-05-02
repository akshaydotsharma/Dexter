import SwiftUI

/// 56pt top bar matching `TopBar.jsx`. Leading hamburger,
/// title in Calistoga 22, theme toggle + AS pip trailing.
struct TopBar: View {
    var title: String?
    var onMenu: () -> Void
    var onToggleTheme: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            Button(action: onMenu) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Tokens.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Open navigation")

            if let title, !title.isEmpty {
                Text(title)
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onToggleTheme) {
                Image(systemName: "sun.max")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Tokens.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Toggle theme")

            // Profile pip — paper coin, not a colored badge.
            Text("AS")
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
                .frame(width: 32, height: 32)
                .background(Tokens.paper2, in: Circle())
                .overlay(Circle().stroke(Tokens.border, lineWidth: 0.5))
                .accessibilityLabel("Akshay")
        }
        .padding(.horizontal, Space.md)
        .frame(height: 56)
        .background(
            Tokens.paper
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Tokens.divider)
                        .frame(height: 0.5)
                }
        )
    }
}

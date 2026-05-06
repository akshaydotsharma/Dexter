import SwiftUI
import UIKit

/// Layout metrics for the bottom tab bar so surfaces can reserve space
/// above their content (especially sticky-bottom UI like the chat input).
enum BottomTabBarMetrics {
    /// Height of the flat tab strip, excluding the safe-area inset.
    static let height: CGFloat = 56
}

/// Persistent bottom tab bar (Navigation v3, issue #48).
///
/// Five symmetric positions: Notes, Lists, [Chat], Tasks, Activity.
/// The centre Chat button sits in a circular pill that lifts above the bar
/// (Stocks / Threads compose pattern), visually separating "summon the AI"
/// from the four passive surfaces.
///
/// The bar is anchored at the root in `ContentView` so it stays visible
/// across surface transitions (tap a note, tap a list — bar stays put).
/// Hides itself while the keyboard is visible so it doesn't fight a
/// chat input bar, inline list-item entry, or the note compose surface
/// (mirrors the previous `ChatFAB` keyboard rule from issue #29).
struct BottomTabBar: View {
    @Bindable var router: AppRouter

    @State private var keyboardVisible = false

    /// Tabs in display order. The centre slot is rendered as the elevated
    /// chat button rather than a flat tab, so the array describes the four
    /// flat tabs only; the centre is interleaved at index 2 in the body.
    private let tabs: [AppSection] = [.notes, .lists, .tasks, .activity]

    /// Height of the flat-tab strip (excluding the safe-area inset and the
    /// portion of the chat circle that lifts above the bar).
    private let barHeight: CGFloat = 56

    /// Diameter of the elevated chat circle.
    private let chatDiameter: CGFloat = 56

    /// How far the centre button rises above the top edge of the bar.
    private let chatLift: CGFloat = 14

    var body: some View {
        ZStack {
            if !keyboardVisible {
                bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.18)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.18)) { keyboardVisible = false }
        }
    }

    // MARK: - Bar layout

    private var bar: some View {
        ZStack(alignment: .top) {
            // Flat strip: 5 equal slots, the middle one left empty so the
            // elevated chat circle drops into it without overlapping a tab.
            HStack(spacing: 0) {
                tab(for: tabs[0])     // Notes
                tab(for: tabs[1])     // Lists
                Color.clear           // centre slot reserved for chat
                    .frame(maxWidth: .infinity)
                tab(for: tabs[2])     // Tasks
                tab(for: tabs[3])     // Activity
            }
            .frame(height: barHeight)
            .background(
                Tokens.surface
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Tokens.divider)
                            .frame(height: 0.5)
                    }
                    .ignoresSafeArea(edges: .bottom)
            )

            // Elevated chat button — anchored to the bar's top edge,
            // floats up by `chatLift`.
            chatButton
                .offset(y: -chatLift)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Flat tab

    private func tab(for section: AppSection) -> some View {
        let isActive = router.currentSection == section
        let accent = Tokens.accent(for: section)

        return Button {
            router.go(to: section)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: section.icon)
                    .font(.system(size: 20, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? accent : Tokens.muted)

                Text(section.displayName)
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? accent : Tokens.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.displayName)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: - Centre chat button

    private var chatButton: some View {
        let isActive = router.currentSection == .chat

        return Button {
            router.popToChat()
        } label: {
            ZStack {
                Circle()
                    .fill(Tokens.ink)
                    .frame(width: chatDiameter, height: chatDiameter)
                    .shadowMd()
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Tokens.paper)
            }
            // Subtle ring when chat is active so the user can read state at
            // a glance even though chat is the implicit "home" surface.
            .overlay(
                Circle()
                    .stroke(Tokens.accentChat.opacity(isActive ? 0 : 0), lineWidth: 0)
                    .frame(width: chatDiameter + 6, height: chatDiameter + 6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chat")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

import SwiftUI
import UIKit

/// Layout metrics for the bottom tab bar so surfaces can reserve space
/// above their content (especially sticky-bottom UI like the chat input).
///
/// `height` is the visual footprint occupied above the home-indicator safe
/// area: pill height + the bottom gap between the pill and the safe-area
/// inset. The chat circle's lift above the pill is intentionally NOT
/// included — surfaces reserve space for the pill body, and the lifted
/// circle is allowed to overlap the surface above (it's a floating
/// element, not a strip of chrome).
enum BottomTabBarMetrics {
    /// Total height reserved above the bottom safe area (pill + bottom gap).
    static let height: CGFloat = 74
}

/// Floating-pill bottom tab bar (Navigation v3, issue #48).
///
/// A capsule-shaped pill insets from the screen edges and floats above the
/// safe area, with a soft drop shadow so it reads as lifted. Four flat tabs
/// sit inside the pill (Notes, Lists, Tasks, Activity); the active tab gets
/// a soft accent-tinted rounded rect behind its icon+label that springs
/// between positions when switching.
///
/// The Chat button is rendered as a separate circular button that floats
/// ABOVE the pill at the centre, overlapping the pill's top edge by ~40%.
/// This preserves the "summon the AI" elevation while keeping the pill
/// itself a clean, unbroken capsule (no notch / cutout).
///
/// Hides itself while the keyboard is visible so it doesn't fight a chat
/// input bar, inline list-item entry, or note compose surfaces.
struct BottomTabBar: View {
    @Bindable var router: AppRouter

    @State private var keyboardVisible = false
    @Namespace private var activePillNamespace

    /// Flat tabs (4 positions inside the pill — chat is the floating circle
    /// rendered separately above).
    private let tabs: [AppSection] = [.notes, .lists, .tasks, .activity]

    // MARK: Pill geometry
    private let pillHeight: CGFloat = 64
    private let pillHorizontalInset: CGFloat = 14
    private let pillBottomGap: CGFloat = 10

    // MARK: Chat circle geometry
    private let chatDiameter: CGFloat = 60
    /// Fraction of the chat diameter that sits ABOVE the pill's top edge.
    /// 0.40 = 40% above, 60% inside the pill. Matches the floating-pill
    /// reference where the centre action overlaps the bar from above.
    private let chatOverlapFraction: CGFloat = 0.40

    var body: some View {
        ZStack {
            if !keyboardVisible {
                pill
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

    // MARK: - Pill

    private var pill: some View {
        // Use a ZStack so the chat circle can float above the pill's top
        // edge without affecting the pill's intrinsic layout.
        ZStack(alignment: .top) {
            // The capsule itself with the four flat tabs inside.
            HStack(spacing: 0) {
                tab(for: tabs[0])               // Notes
                tab(for: tabs[1])               // Lists
                Color.clear                     // centre slot reserved for chat circle overlap
                    .frame(maxWidth: .infinity)
                tab(for: tabs[2])               // Tasks
                tab(for: tabs[3])               // Activity
            }
            .frame(height: pillHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(Tokens.surface)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Tokens.border, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.10), radius: 18, x: 0, y: 8)
            .padding(.horizontal, pillHorizontalInset)
            .padding(.bottom, pillBottomGap)

            // Floating chat circle, anchored to the centre of the pill and
            // lifted so a fraction of the diameter sits above the pill's
            // top edge (Option A — clean unbroken capsule + overlapping
            // FAB-style action).
            chatButton
                .offset(y: -(chatDiameter * chatOverlapFraction))
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
            ZStack {
                // The active-state rounded rect "pill" sits BEHIND the
                // icon+label. Only the active tab renders it; the
                // matchedGeometryEffect makes it slide between positions
                // when the user switches tabs.
                if isActive {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent.opacity(0.14))
                        .matchedGeometryEffect(id: "activePill", in: activePillNamespace)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                }

                VStack(spacing: 3) {
                    Image(systemName: section.icon)
                        .font(.system(size: 20, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? accent : Tokens.muted)

                    Text(section.displayName)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? accent : Tokens.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.displayName)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: router.currentSection)
    }

    // MARK: - Floating chat circle

    private var chatButton: some View {
        let isActive = router.currentSection == .chat

        return Button {
            router.popToChat()
        } label: {
            ZStack {
                Circle()
                    .fill(Tokens.ink)
                    .frame(width: chatDiameter, height: chatDiameter)

                // Subtle outer rim so the circle reads as a distinct object
                // when it overlaps the pill, even at the same tonality.
                Circle()
                    .stroke(Tokens.surface, lineWidth: 3)
                    .frame(width: chatDiameter, height: chatDiameter)

                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Tokens.paper)
            }
            // Heavier shadow than the pill so the circle reads as floating
            // even higher.
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
            .scaleEffect(isActive ? 1.0 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chat")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

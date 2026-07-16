import SwiftUI
import UIKit

// `BottomTabBarMetrics` moved to BottomTabBarMetrics.swift (UIKit-free) so
// surfaces can reserve space without depending on this iOS-only view.

/// Floating-pill bottom tab bar (Navigation v3, issue #48).
///
/// A capsule-shaped pill insets from the screen edges and floats above the
/// safe area, with a soft drop shadow so it reads as lifted. Four icon-only
/// flat tabs sit inside the pill (Notes, Lists, Tasks, Activity); the
/// active tab gets a soft accent-tinted rounded rect behind its icon that
/// springs between positions when switching.
///
/// The Chat button is rendered as a separate circular button that floats
/// ABOVE the pill at the centre, overlapping the pill's top edge by a
/// small fraction so it reads as "elevated but anchored" rather than
/// floating away. On the Chat surface itself the circle is hidden (it
/// would be redundant and would overlap the chat input) — the centre slot
/// stays reserved as a transparent spacer so the four flat tabs don't
/// shift position when navigating between Chat and other surfaces.
///
/// Hides itself while the keyboard is visible so it doesn't fight a chat
/// input bar, inline list-item entry, or note compose surfaces.
struct BottomTabBar: View {
    @Bindable var router: AppRouter

    @State private var keyboardVisible = false
    /// True while the chat circle is being pressed (drives the press-down
    /// scale). Set/cleared by the long-press gesture's `onPressingChanged`.
    @State private var isPressingChat = false
    @Namespace private var activePillNamespace

    /// Flat tabs (4 positions inside the pill — chat is the floating circle
    /// rendered separately above).
    private let tabs: [AppSection] = [.notes, .lists, .tasks, .activity]

    // MARK: Pill geometry
    private let pillHeight: CGFloat = 64
    /// Inset from the screen edges. Wider inset reads as a "floating
    /// island" rather than a full-width strip — matches the floating
    /// nav-bar pattern in apps like Flow / Threads.
    private let pillHorizontalInset: CGFloat = 22
    /// Gap between the pill's bottom edge and the home-indicator safe area.
    /// 0pt = pill sits flush against the safe-area top; the home indicator
    /// still gets its standard inset below.
    private let pillBottomGap: CGFloat = 0

    // MARK: Chat circle geometry
    private let chatDiameter: CGFloat = 60
    /// Fraction of the chat diameter that sits ABOVE the pill's top edge.
    /// 0.18 = 18% above, 82% inside the pill — the circle reads as a
    /// distinct lifted button (heavier shadow + surface-coloured rim) but
    /// stays anchored to the bar instead of looking like a free-floating
    /// object hovering away from it.
    private let chatOverlapFraction: CGFloat = 0.18

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
            //
            // Centre slot:
            // - On non-chat surfaces, an invisible spacer the floating chat
            //   circle hovers above (Option A overlap pattern).
            // - On the Chat surface itself, a flat chat tab takes the slot
            //   so the bar reads as a normal 5-tab capsule with the active
            //   tab highlighted in place.
            HStack(spacing: 0) {
                tab(for: tabs[0])               // Notes
                tab(for: tabs[1])               // Lists
                Group {
                    if router.currentSection == .chat {
                        tab(for: .chat)         // flat chat tab with active highlight
                    } else {
                        Color.clear             // reserved for the floating circle
                            .frame(maxWidth: .infinity)
                    }
                }
                tab(for: tabs[2])               // Tasks
                tab(for: tabs[3])               // Activity
            }
            .frame(height: pillHeight)
            // Liquid-glass pill — `.ultraThinMaterial` blurs the content
            // behind the bar so it adapts to the surface (dark/light, busy
            // list, empty space) instead of fighting the background with a
            // solid fill. A whisper of `Tokens.surface` on top keeps the
            // bar legible when the content underneath is pure black or
            // pure paper.
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .background(
                Capsule(style: .continuous)
                    .fill(Tokens.surface.opacity(0.18))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Tokens.border.opacity(0.5), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.20), radius: 24, x: 0, y: 12)
            .padding(.horizontal, pillHorizontalInset)
            .padding(.bottom, pillBottomGap)

            // Floating chat circle, anchored to the centre of the pill and
            // lifted so a fraction of the diameter sits above the pill's
            // top edge (Option A — clean unbroken capsule + overlapping
            // FAB-style action).
            //
            // On the Chat surface the circle would be redundant AND would
            // overlap the chat input bar, so we render a transparent
            // spacer of the same frame instead. This keeps the pill's
            // centre slot reserved at the same width so the four flat
            // tabs don't shift position when switching to/from Chat.
            Group {
                if router.currentSection == .chat {
                    Color.clear
                        .frame(width: chatDiameter, height: chatDiameter)
                } else {
                    chatButton
                }
            }
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
                    // Neutral muted highlight for the Chat tab (its accent
                    // is cream in dark mode and reads as a near-white pill,
                    // which is too loud for an "active" cue). Per-tab
                    // accents continue to drive the highlight on every
                    // other tab.
                    let highlightFill: Color = section == .chat
                        ? Tokens.muted.opacity(0.18)
                        : accent.opacity(0.14)

                    // Capsule-shaped highlight so the leftmost (Notes) and
                    // rightmost (Activity) tabs' active backgrounds nest
                    // cleanly inside the pill's rounded ends instead of
                    // colliding with them at 90° corners.
                    Capsule(style: .continuous)
                        .fill(highlightFill)
                        .matchedGeometryEffect(id: "activePill", in: activePillNamespace)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                }

                // Icon-only tab — labels were dropped after on-device
                // review of the floating-pill layout (the pill is narrow
                // and the icons are recognisable on their own; the
                // accent-tinted active background is enough state cue).
                Image(systemName: section.icon)
                    .font(.system(size: 22, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? accent : Tokens.muted)
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

        // NOT a Button. A Button + `.simultaneousGesture(LongPressGesture)`
        // lets BOTH recognizers fire: the hold presents the overlay AND the
        // Button's tap action still runs on touch-up, navigating to chat
        // (issue #150 device QA). Pairing `.onTapGesture` with
        // `.onLongPressGesture` instead makes them mutually exclusive —
        // SwiftUI cancels the pending tap once the long-press succeeds, so a
        // completed hold never triggers `popToChat()`. Tap and hold are now
        // distinct outcomes:
        //   • quick TAP  → router.popToChat()        (open chat to type)
        //   • HOLD ≥0.6s → haptic + show overlay      (stay on current page)
        return ZStack {
            Circle()
                .fill(Tokens.ink)
                .frame(width: chatDiameter, height: chatDiameter)

            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Tokens.paper)
        }
        // Shadow alone lifts the circle off the pill in both themes — a
        // paper/surface rim was producing a white halo in light mode (the
        // dark circle already has plenty of natural contrast against a light
        // pill, so the rim was over-engineering).
        .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 7)
        // Subtle press-down feedback: scale to 0.92 while the finger is held,
        // spring back on release / cancel (concept doc Section 3).
        .scaleEffect(isPressingChat ? 0.92 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isPressingChat)
        .contentShape(Circle())
        // Long-press FIRST so its `pressing` callback drives the scale and a
        // successful hold cancels the tap below.
        .onLongPressGesture(
            minimumDuration: 0.6,
            perform: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                router.showVoiceOverlay = true
            },
            onPressingChanged: { pressing in
                isPressingChat = pressing
            }
        )
        .onTapGesture {
            router.popToChat()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chat")
        .accessibilityHint("Double tap to open chat. Touch and hold to start voice input.")
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : [.isButton])
    }
}

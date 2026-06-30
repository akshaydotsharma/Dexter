import SwiftUI
import UIKit

/// Global full-screen voice-capture overlay (issue #150, auto-execute concept).
///
/// Presented once from `ContentView`'s root via `.fullScreenCover` bound to
/// `AppRouter.showVoiceOverlay`, so it covers whatever tab the user was on
/// without navigating — dismiss returns to the same page/scroll. Renders the
/// state machine in `VoiceCaptureViewModel` (A / A1 / C / D / E / F / G) as a
/// pure projection of `vm.state`. All teardown funnels through the cover's
/// `onDismiss` → `vm.teardown()`.
///
/// Layout (concept doc Section 3): top bar (status + Cancel), animation zone
/// (InkOrb, upper portion), divider, transcript zone, bottom control zone.
struct VoiceCaptureOverlay: View {
    @Bindable var vm: VoiceCaptureViewModel
    /// Bound to `router.showVoiceOverlay`; set false to dismiss the cover.
    @Binding var isPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("hasSeenVoiceHint") private var hasSeenVoiceHint: Bool = false

    var body: some View {
        GeometryReader { geo in
            let animationFraction: CGFloat = dynamicTypeSize > .xxLarge ? 0.30 : 0.38

            ZStack {
                Tokens.surface.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                        .frame(height: 52)
                        .padding(.horizontal, Space.xl)

                    // Animation zone — InkOrb centered.
                    ZStack {
                        InkOrb(mode: orbMode, level: vm.audioLevel)
                    }
                    .frame(height: geo.size.height * animationFraction)
                    .frame(maxWidth: .infinity)

                    Divider().overlay(Tokens.border)

                    // Transcript / body zone.
                    bodyZone
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Bottom control zone.
                    bottomZone
                        .frame(minHeight: 80)
                        .padding(.horizontal, Space.xl)
                        .padding(.bottom, Space.sm)
                }
            }
        }
        .preferredColorScheme(nil)
        .interactiveDismissDisabled(!vm.allowsInteractiveDismiss)
        .onAppear {
            vm.begin()
            UIAccessibility.post(notification: .announcement, argument: "Recording in progress.")
        }
        .onChange(of: vm.transcript) { _, _ in
            vm.scheduleSilenceFinalize()
        }
        .onChange(of: vm.state) { _, newState in
            announce(for: newState)
            if newState != .listening, !vm.transcript.isEmpty, !hasSeenVoiceHint {
                hasSeenVoiceHint = true
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.2), value: vm.state)
    }

    // MARK: - Top bar

    @ViewBuilder
    private var topBar: some View {
        HStack(alignment: .center) {
            Text(statusLabel)
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .transition(.opacity)
                .id(statusLabel)  // cross-fade on change

            Spacer(minLength: Space.md)

            if let action = topRightControl {
                Button(action.title) { action.run() }
                    .buttonStyle(GlassButtonStyle(font: .edCaption))
                    .accessibilityLabel(action.a11y)
            }
        }
    }

    private var statusLabel: String {
        switch vm.state {
        case .listening:        return "Listening"
        case .safetyWindow:     return "Got it"
        case .executing:        return "Working…"
        case .success:          return "Done"
        case .empty:            return "Nothing heard"
        case .permissionDenied: return "Microphone access needed"
        case .error:            return "Something went wrong"
        }
    }

    /// (title, accessibility label, action) for the top-right glass control.
    private var topRightControl: (title: String, a11y: String, run: () -> Void)? {
        switch vm.state {
        case .listening, .safetyWindow, .executing:
            return ("Cancel", "Cancel voice capture", { isPresented = false })
        case .empty:
            return ("Cancel", "Cancel voice capture", { isPresented = false })
        case .permissionDenied:
            return ("Not now", "Not now", { isPresented = false })
        case .error:
            return ("Dismiss", "Dismiss", { isPresented = false })
        case .success:
            return nil  // no buttons in Done
        }
    }

    // MARK: - Body zone

    @ViewBuilder
    private var bodyZone: some View {
        switch vm.state {
        case .listening:
            transcriptScroll(static: false)
        case .safetyWindow:
            transcriptScroll(static: true)
        case .executing:
            executingBody
        case .success:
            successBody
        case .empty:
            centeredMessage("Try speaking, or tap the mic to record again.")
        case .permissionDenied:
            centeredMessage("Dexter needs microphone and speech access to record your voice. Turn them on in Settings to continue.")
        case .error(let message):
            centeredMessage(message)
        }
    }

    /// State A / A1 transcript. `static` true freezes the cursor (A1).
    private func transcriptScroll(static isStatic: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if vm.transcript.isEmpty && !isStatic {
                        if !hasSeenVoiceHint {
                            Text("Start speaking — Dexter is listening.")
                                .font(.edCaption)
                                .foregroundStyle(Tokens.muted)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, Space.xl)
                        }
                    } else {
                        HStack(alignment: .lastTextBaseline, spacing: 2) {
                            Text(vm.transcript)
                                .font(.edBody)
                                .foregroundStyle(Tokens.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if !isStatic {
                                BlinkingCursor(reduceMotion: reduceMotion)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.lg)
            }
            .onChange(of: vm.transcript) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    // State C — muted static transcript + typing indicator.
    private var executingBody: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(vm.finalizedTranscript)
                .font(.edBody)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)

            TypingIndicator()
                .transition(.opacity)
                .accessibilityLabel("Processing your request.")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.lg)
    }

    // State D — success rows.
    private var successBody: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(Array(vm.successLabels.enumerated()), id: \.offset) { _, label in
                SuccessRow(label: label)
                    .transition(
                        reduceMotion ? .opacity
                                     : .opacity.combined(with: .move(edge: .bottom))
                    )
                    .accessibilityHidden(true)  // announced via VoiceOver post
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.lg)
    }

    private func centeredMessage(_ text: String) -> some View {
        VStack {
            Spacer(minLength: 0)
            Text(text)
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl)
    }

    // MARK: - Bottom control zone

    @ViewBuilder
    private var bottomZone: some View {
        switch vm.state {
        case .listening:
            // Stop Now, centered.
            HStack {
                Spacer()
                Button("Stop Now") { vm.stopNow() }
                    .buttonStyle(GlassButtonStyle())
                    .accessibilityLabel("Stop and execute")
                Spacer()
            }

        case .safetyWindow:
            // Secondary Cancel (thumb reach) + sweeping progress bar.
            HStack(spacing: Space.lg) {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(GlassButtonStyle())
                    .accessibilityLabel("Cancel voice capture")
                SafetyProgressBar(duration: 1.5)
                    .accessibilityHidden(true)
            }

        case .executing:
            // No bottom control — only the top Cancel.
            Color.clear.frame(height: 1)

        case .success:
            // Auto-dismiss progress line.
            AutoDismissProgressLine(reduceMotion: reduceMotion) {
                isPresented = false
            }
            .accessibilityHidden(true)

        case .empty:
            twoGlass(
                left: ("Cancel", "Cancel voice capture", { isPresented = false }),
                right: ("Try Again", "Try again", { Task { await vm.startListening() } })
            )

        case .permissionDenied:
            twoGlass(
                left: ("Not now", "Not now", { isPresented = false }),
                right: ("Open Settings", "Open Settings", { vm.openSettings() })
            )

        case .error:
            twoGlass(
                left: ("Dismiss", "Dismiss", { isPresented = false }),
                right: ("Try Again", "Try again", { vm.retryExecute() })
            )
        }
    }

    private func twoGlass(
        left: (String, String, () -> Void),
        right: (String, String, () -> Void)
    ) -> some View {
        HStack {
            Button(left.0) { left.2() }
                .buttonStyle(GlassButtonStyle())
                .accessibilityLabel(left.1)
            Spacer()
            Button(right.0) { right.2() }
                .buttonStyle(GlassButtonStyle())
                .accessibilityLabel(right.1)
        }
    }

    // MARK: - InkOrb mode mapping

    private var orbMode: InkOrb.Mode {
        switch vm.state {
        case .listening:        return .listening
        case .safetyWindow:     return .settled
        case .executing:        return .thinking
        case .success:          return .rest
        case .empty:            return .idle
        case .permissionDenied: return .dim
        case .error:            return .dim
        }
    }

    // MARK: - Accessibility announcements

    private func announce(for state: VoiceCaptureViewModel.State) {
        switch state {
        case .safetyWindow:
            UIAccessibility.post(notification: .announcement,
                                 argument: "Executing in 1.5 seconds. Double tap Cancel to abort.")
        case .executing:
            UIAccessibility.post(notification: .announcement, argument: "Processing your request.")
        case .success:
            for (idx, label) in vm.successLabels.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(idx) * 0.5) {
                    UIAccessibility.post(notification: .announcement, argument: label)
                }
            }
            let after = Double(vm.successLabels.count) * 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                UIAccessibility.post(notification: .announcement, argument: "Closing in 2 seconds.")
            }
        default:
            break
        }
    }
}

// MARK: - Blinking transcript cursor

private struct BlinkingCursor: View {
    let reduceMotion: Bool
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(Tokens.ink)
            .frame(width: 2, height: 18)
            .opacity(reduceMotion ? 1 : (visible ? 1 : 0))
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

// MARK: - Safety-window sweeping progress bar (A1)

/// 1pt ink-30% bar that sweeps 0 → full width over `duration` (linear). It is
/// informational, so it animates even under reduce-motion (Apple's guidance).
private struct SafetyProgressBar: View {
    let duration: Double
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Tokens.ink.opacity(0.30))
                .frame(width: geo.size.width * progress, height: 1)
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 44)
        .onAppear {
            withAnimation(.linear(duration: duration)) { progress = 1 }
        }
    }
}

// MARK: - Auto-dismiss progress line (D)

/// 1pt ink-20% line that depletes over 2.0s, then dismisses. Informational, so
/// it animates under reduce-motion too.
private struct AutoDismissProgressLine: View {
    let reduceMotion: Bool
    let onComplete: () -> Void
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Tokens.ink.opacity(0.2))
                .frame(width: geo.size.width * progress, height: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 1)
        .onAppear {
            withAnimation(.linear(duration: 2.0)) { progress = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { onComplete() }
        }
    }
}

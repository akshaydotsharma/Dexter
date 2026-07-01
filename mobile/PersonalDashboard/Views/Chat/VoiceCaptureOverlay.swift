import SwiftUI
import UIKit

/// Global full-screen voice-capture overlay (issue #150 → #156, one-shot).
///
/// Presented once from `ContentView`'s root via `.fullScreenCover` bound to
/// `AppRouter.showVoiceOverlay`, so it covers whatever tab the user was on
/// without navigating — dismiss returns to the same page/scroll. Renders the
/// one-shot state machine in `VoiceCaptureViewModel` (listening → executing →
/// flashSuccess → auto-dismiss; plus empty / error / permissionDenied) as a pure
/// projection of `vm.state`. On success the overlay AUTO-DISMISSES: the VM flips
/// `vm.shouldDismiss`, an `.onChange` here sets `isPresented = false`, and the
/// cover's `onDismiss` → `vm.teardown()` cleans up. Empty / error stay open for
/// Try Again; Done / Cancel bail through the same `onDismiss`.
///
/// Layout: top bar (status + Done), animation zone (InkOrb, upper portion),
/// divider, transcript zone, bottom control zone.
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
            UIAccessibility.post(notification: .announcement, argument: "Listening. Speak one command.")
        }
        .onChange(of: vm.transcriber.errorMessage) { _, message in
            // A connection failure (or other transcriber error) arriving async
            // while we're listening must route the overlay to State G with the
            // friendly message instead of hanging in "Listening" (issue #151).
            if let message, !message.isEmpty {
                vm.handleTranscriberError(message)
            }
        }
        .onChange(of: vm.state) { _, newState in
            announce(for: newState)
            if newState != .listening, !vm.transcript.isEmpty, !hasSeenVoiceHint {
                hasSeenVoiceHint = true
            }
        }
        // One-shot auto-dismiss (issue #156): after the success flash the VM flips
        // `shouldDismiss`; close the cover, which funnels through `onDismiss` →
        // `vm.teardown()`. The VM never touches this binding directly.
        .onChange(of: vm.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss { isPresented = false }
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
        case .executing:        return "Working…"
        case .flashSuccess:     return "Done"
        case .empty:            return "Nothing heard"
        case .permissionDenied: return "Microphone access needed"
        case .error:            return "Something went wrong"
        }
    }

    /// (title, accessibility label, action) for the top-right glass control.
    /// While `.listening` this is "Cancel" — it bails WITHOUT executing, kept
    /// clearly distinct from the primary "Stop Recording" button below (which
    /// runs the command). Labelled "Done" in the passive executing / flash /
    /// empty states where there's nothing to cancel. On success the overlay
    /// auto-dismisses, so this is an escape hatch, not the only way out (#156).
    private var topRightControl: (title: String, a11y: String, run: () -> Void)? {
        switch vm.state {
        case .listening:
            return ("Cancel", "Cancel, close voice capture without running anything", { isPresented = false })
        case .executing, .flashSuccess, .empty:
            return ("Done", "Done, close voice capture", { isPresented = false })
        case .permissionDenied:
            return ("Not now", "Not now", { isPresented = false })
        case .error:
            return ("Dismiss", "Dismiss", { isPresented = false })
        }
    }

    // MARK: - Body zone

    @ViewBuilder
    private var bodyZone: some View {
        switch vm.state {
        case .listening:
            transcriptScroll(static: false)
        case .executing:
            executingBody
        case .flashSuccess:
            successBody
        case .empty:
            centeredMessage("Try speaking, or tap Try Again to keep listening.")
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

    // Executing — the utterance being processed, muted, + typing indicator.
    private var executingBody: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(vm.currentUtterance)
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

    // Flash — this utterance's success rows (cleared automatically after ~1.5s
    // by the view model, which then returns to .listening).
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
            // Primary "Stop Recording" — ends capture NOW and runs the command
            // spoken so far, instead of waiting for the automatic pause/VAD
            // finalize (issue #156). Prominent, centered. Bailing without running
            // is the top-right "Cancel"; the two are deliberately distinct.
            HStack {
                Spacer()
                Button("Stop Recording") { vm.stopRecordingAndExecute() }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .accessibilityLabel("Stop recording and run what you said")
                    .accessibilityHint("Ends listening and processes your command now")
                Spacer()
            }

        case .executing, .flashSuccess:
            // No bottom control mid-cycle — the top Done still bails, and the
            // overlay auto-dismisses once the flash elapses.
            Color.clear.frame(height: 1)

        case .empty:
            twoGlass(
                left: ("Done", "Done, close voice capture", { isPresented = false }),
                right: ("Try Again", "Try again", { vm.retryExecute() })
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
        case .executing:        return .thinking
        case .flashSuccess:     return .rest
        case .empty:            return .idle
        case .permissionDenied: return .dim
        case .error:            return .dim
        }
    }

    // MARK: - Accessibility announcements

    private func announce(for state: VoiceCaptureViewModel.State) {
        switch state {
        case .executing:
            UIAccessibility.post(notification: .announcement, argument: "Processing your request.")
        case .flashSuccess:
            for (idx, label) in vm.successLabels.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(idx) * 0.5) {
                    UIAccessibility.post(notification: .announcement, argument: label)
                }
            }
            let after = Double(vm.successLabels.count) * 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                UIAccessibility.post(notification: .announcement, argument: "Done. Closing voice capture.")
            }
        case .listening:
            UIAccessibility.post(notification: .announcement, argument: "Listening.")
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


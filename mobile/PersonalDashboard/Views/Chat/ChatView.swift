import SwiftUI
import UIKit

struct ChatView: View {
    @State private var viewModel = ChatViewModel()
    @State private var transcriber = SpeechTranscriber()
    @State private var pendingViewMore: Bool = false
    @State private var keyboardVisible: Bool = false
    /// Whatever the user had typed at the moment they tapped the mic.
    /// While recording we replace the input field with `baseline + transcript`
    /// so partials feel live; tapping mic-stop with an empty transcript
    /// restores the baseline so we don't clobber typed text on a misfire.
    @State private var preMicBaseline: String = ""

    /// Owned here so we can auto-focus the input bar when the user lands on
    /// chat (issue #48 — tapping the chat icon should pop the keyboard
    /// straight away so the surface defaults to "ready to type").
    @FocusState private var inputFocused: Bool

    @Bindable var router: AppRouter

    private let examples = [
        "Remind me to call John tomorrow at 3",
        "New shopping list with milk, eggs, bread",
        "Note: ideas for Q3 OKRs"
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Tokens.paper
                .ignoresSafeArea()
                // Tap on empty paper background dismisses the keyboard so
                // the floating tab bar comes back into view (issue #48).
                .onTapGesture {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }

            VStack(spacing: 0) {
                // Top bar + body area: any tap dismisses the keyboard.
                // simultaneousGesture fires ALONGSIDE child gestures, so
                // scrolling, tapping messages, and tapping suggestion chips
                // all keep working — they just additionally drop the
                // keyboard. The ChatInputBar is intentionally outside this
                // gesture so tapping the text field still focuses it.
                VStack(spacing: 0) {
                    TopBar(
                        title: viewModel.turns.isEmpty ? nil : "Chat",
                        onMenu: {
                            router.openDrawer()
                        }
                    )

                    if viewModel.turns.isEmpty {
                        emptyState
                    } else {
                        conversation
                    }
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                    }
                )

                if let micError = transcriber.errorMessage {
                    // Restrained inline note above the input bar — matches
                    // the design vocabulary (Tokens.surface bg, muted text).
                    // Tap to dismiss so the bar reclaims its room.
                    HStack(spacing: Space.xs) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Tokens.muted)
                        Text(micError)
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .background(
                        Tokens.surface,
                        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    )
                    .paperBorder(Tokens.border, radius: Radius.md)
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.xs)
                    .onTapGesture { transcriber.errorMessage = nil }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                ChatInputBar(
                    text: $viewModel.draftInput,
                    isSending: viewModel.isSending,
                    onSend: send,
                    onMic: { Task { await toggleMic() } },
                    isMicActive: transcriber.isRecording,
                    focused: $inputFocused
                )
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.sm)
                // Reserve room for the bottom tab bar so the input bar
                // doesn't hide behind it. When the keyboard is up, the bar
                // hides and the keyboard pushes the input up directly. The
                // gap above the tab bar is intentionally small so the input
                // sits visually close to the floating pill.
                .padding(.bottom, keyboardVisible ? Space.md : BottomTabBarMetrics.height)
            }
        }
        .background(Tokens.paper)
        .onAppear {
            // Land in keyboard-up state on first appearance. The small
            // delay gives SwiftUI time to lay the view tree out before
            // we ask the TextField to take first responder.
            if router.currentSection == .chat {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    inputFocused = true
                }
            }
        }
        .onChange(of: router.currentSection) { _, newSection in
            // Tapping the chat circle from any other surface should drop
            // the user straight into typing (issue #48).
            if newSection == .chat {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    inputFocused = true
                }
            }
        }
        .onChange(of: transcriber.transcript) { _, newTranscript in
            // Mirror live partials into the existing TextField so the user
            // sees the transcription appear in real time. Append to the
            // baseline (whatever was typed before mic-tap) instead of
            // replacing — keeps already-typed context intact.
            guard transcriber.isRecording else { return }
            if newTranscript.isEmpty {
                viewModel.draftInput = preMicBaseline
            } else if preMicBaseline.isEmpty {
                viewModel.draftInput = newTranscript
            } else {
                viewModel.draftInput = preMicBaseline + " " + newTranscript
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.18)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.18)) { keyboardVisible = false }
        }
        .alert("Something went wrong",
               isPresented: Binding(
                   get: { viewModel.errorMessage != nil },
                   set: { if !$0 { viewModel.errorMessage = nil } }
               )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Space.xxxl)

            VStack(spacing: Space.lg) {
                LogoBars(
                    isAnimating: viewModel.draftInput.trimmingCharacters(in: .whitespaces).isEmpty
                )

                VStack(spacing: Space.md) {
                    Text("What can I help you organize?")
                        .font(.edDisplay)
                        .foregroundStyle(Tokens.ink)
                        .multilineTextAlignment(.center)
                        .tracking(-0.4)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Ask for a task, a note, or a list. I'll add it for you and link straight to it.")
                        .font(.edBody)
                        .foregroundStyle(Tokens.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .padding(.top, Space.xs)

                VStack(spacing: Space.sm) {
                    ForEach(examples, id: \.self) { example in
                        ExampleChip(text: example) {
                            viewModel.draftInput = example
                        }
                    }
                }
                .padding(.top, Space.md)
            }
            .padding(.horizontal, Space.xl)

            Spacer(minLength: Space.xxxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Conversation list

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.lg) {
                    // Keep ScrollView empty-area taps dismissing the keyboard
                    // (in addition to drag-to-dismiss below) so users can
                    // tap a message bubble's empty margin to dismiss too.
                    ForEach(viewModel.turns) { turn in
                        TurnView(
                            turn: turn,
                            onOpen: { result in openResult(result) }
                        )
                        .id(turn.id)
                    }

                    // Show typing indicator only when we don't have an
                    // assistant turn yet streaming text (the live turn shows
                    // its own cursor — see TurnView).
                    if viewModel.isSending && !hasLiveAssistantTurn {
                        TypingIndicator()
                            .padding(.top, Space.xs)
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.turns.count) { _, _ in
                if let last = viewModel.turns.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func send() {
        // Flush any in-flight transcription first so the final partial
        // lands in `draftInput` before the message ships.
        if transcriber.isRecording {
            transcriber.stop()
        }
        Task { await viewModel.send() }
    }

    private func toggleMic() async {
        if transcriber.isRecording {
            transcriber.stop()
        } else {
            // Snapshot what's already in the field so live partials append
            // to it rather than overwriting typed context.
            preMicBaseline = viewModel.draftInput
            await transcriber.toggle()
        }
    }

    private var hasLiveAssistantTurn: Bool {
        viewModel.turns.last?.isStreaming == true
    }

    /// Resolve the result's deep-link target and route. We set the focus
    /// payload BEFORE pushing the section so the destination view's
    /// `onAppear` reads a non-nil focus on the very first render and the
    /// row scroll + accent pulse fires without a frame of empty content.
    private func openResult(_ result: ChatActionResult) {
        guard let outcome = result.outcome,
              let section = result.deepLinkSection,
              let uuid = UUID(uuidString: outcome.id)
        else { return }
        let isFolder = outcome.type == "folder"
        router.focus = ActivityFocus(section: section, id: uuid, isFolder: isFolder)
        router.go(to: section)
    }
}

/// Three pill-capped bars + accent dot mirroring the Deks logo (top 55%,
/// middle 85%, bottom 70%, dot just past the end of the top bar). The
/// bars are anchored at the leading edge; each bar's *length* oscillates
/// continuously around its logo width, with its own period and phase so
/// the trio feels organic rather than metronomic. The accent dot rides
/// the right edge of the top bar so the silhouette stays coherent. When
/// the user starts typing, the bars snap back to exact logo widths.
private struct LogoBars: View {
    let isAnimating: Bool

    private let middleWidth: CGFloat = 48
    private let barHeight: CGFloat = 5
    private let gap: CGFloat = 4
    private let dotDiameter: CGFloat = 4
    private let topRatio: CGFloat = 55.0 / 85.0
    private let bottomRatio: CGFloat = 70.0 / 85.0
    /// Logo: top bar ends at x=640, dot center at x=700 (delta 60 of 870).
    private let dotGapRatio: CGFloat = 60.0 / 870.0
    /// Maximum length deviation from the logo width, as a fraction.
    private let modulation: CGFloat = 0.18

    var body: some View {
        let topBase = middleWidth * topRatio
        let bottomBase = middleWidth * bottomRatio
        let maxMiddle = middleWidth * (1 + modulation)
        let containerWidth = maxMiddle + middleWidth * dotGapRatio + dotDiameter

        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isAnimating)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let mod = isAnimating ? modulation : 0

            // Each bar runs on its own period and phase so the three never
            // line up — keeps the motion feeling unscripted.
            let topW    = animatedWidth(base: topBase,     time: t, period: 1.70, phase: 0.0, modulation: mod)
            let middleW = animatedWidth(base: middleWidth, time: t, period: 2.40, phase: 0.6, modulation: mod)
            let bottomW = animatedWidth(base: bottomBase,  time: t, period: 3.10, phase: 1.2, modulation: mod)

            // Dot rides the right edge of the top bar with the same offset
            // ratio as the logo (60 / 870 of the middle width).
            let dotLeading = topW + middleWidth * dotGapRatio - dotDiameter / 2

            VStack(alignment: .leading, spacing: gap) {
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Tokens.ink)
                        .frame(width: topW, height: barHeight)

                    Circle()
                        .fill(Tokens.ink)
                        .frame(width: dotDiameter, height: dotDiameter)
                        .offset(x: dotLeading)
                }
                .frame(height: barHeight)

                Capsule(style: .continuous)
                    .fill(Tokens.ink)
                    .frame(width: middleW, height: barHeight)

                Capsule(style: .continuous)
                    .fill(Tokens.ink)
                    .frame(width: bottomW, height: barHeight)
            }
            .frame(width: containerWidth, alignment: .leading)
        }
    }

    /// Width of a bar at time `t`. A primary sine carries the breath, a
    /// shorter secondary sine adds wobble so the cycle never reads as a
    /// clean sinusoid.
    private func animatedWidth(
        base: CGFloat,
        time t: Double,
        period: Double,
        phase: Double,
        modulation: CGFloat
    ) -> CGFloat {
        guard modulation > 0 else { return base }
        let primary = sin(2 * .pi * t / period + phase)
        let wobble = sin(2 * .pi * t / (period * 0.62) + phase * 1.4) * 0.45
        let combined = CGFloat((primary + wobble) / 1.45)
        return base * (1 + modulation * combined)
    }
}

private struct TurnView: View {
    let turn: ChatTurn
    let onOpen: (ChatActionResult) -> Void

    var body: some View {
        VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: Space.md) {
            if !turn.text.isEmpty || turn.isStreaming {
                if turn.role == .user {
                    UserBubble(text: turn.text)
                } else {
                    StreamingProse(text: turn.text, isStreaming: turn.isStreaming)
                }
            }

            ForEach(turn.results) { result in
                ChatResultCard(
                    result: result,
                    onOpen: result.supportsDeepLink ? { onOpen(result) } : nil
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
    }
}

/// AI prose with an optional blinking cursor while text is streaming in.
/// While the text is empty and isStreaming=true, shows just the cursor.
private struct StreamingProse: View {
    let text: String
    let isStreaming: Bool

    @State private var cursorVisible = true

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            if !text.isEmpty {
                AIProse(text: text)
            }
            if isStreaming {
                Rectangle()
                    .fill(Tokens.ink)
                    .frame(width: 2, height: 18)
                    .opacity(cursorVisible ? 1 : 0)
                    .padding(.bottom, 2)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                            cursorVisible = false
                        }
                    }
            }
        }
    }
}

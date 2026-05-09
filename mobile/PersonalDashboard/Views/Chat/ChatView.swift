import SwiftUI
import UIKit

struct ChatView: View {
    @State private var viewModel = ChatViewModel()
    @State private var transcriber = SpeechTranscriber()
    @State private var resolvedDrafts: [UUID: DraftPreviewCard.Resolution] = [:]
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

                    Text("Ask for a task, a note, or a list. I'll draft it for you to confirm.")
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
                            resolvedDrafts: resolvedDrafts,
                            onConfirm: { draft in
                                Task {
                                    let ok = await viewModel.confirm(draft)
                                    if ok {
                                        resolvedDrafts[draft.id] = .confirmed
                                    }
                                }
                            },
                            onCancel: { draft in
                                // Reject is purely a UI operation now — record
                                // the resolution before the model removes the
                                // draft from its turn so the card animates out
                                // showing the "Cancelled" state.
                                resolvedDrafts[draft.id] = .cancelled
                                viewModel.reject(draft)
                            }
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
}

/// Three pill-capped bars + accent dot mirroring the Deks logo (top 55%,
/// middle 85%, bottom 70%, dot just past the end of the top bar). While
/// the chat empty state is showing and the input is untouched, the bar
/// thickness itself ripples in a horizontal sine wave that travels from
/// the leading to the trailing edge on loop — the bars stay solid (no
/// overlay), they just bulge and pinch. The wave snaps flat the moment
/// the user starts typing.
private struct LogoBars: View {
    let isAnimating: Bool

    private let middleWidth: CGFloat = 48
    private let baseHeight: CGFloat = 5
    private let amplitude: CGFloat = 1.0
    private let wavelength: CGFloat = 18
    private let gap: CGFloat = 4
    private let dotDiameter: CGFloat = 4
    private let topRatio: CGFloat = 55.0 / 85.0
    private let bottomRatio: CGFloat = 70.0 / 85.0
    /// Logo: top bar ends at x=640, dot center at x=700 (delta 60 of 870).
    private let dotGapRatio: CGFloat = 60.0 / 870.0
    private let cycleSeconds: Double = 2.6

    var body: some View {
        let topWidth = middleWidth * topRatio
        let bottomWidth = middleWidth * bottomRatio
        let dotLeading = topWidth + middleWidth * dotGapRatio - dotDiameter / 2
        let rowHeight = baseHeight + amplitude * 2

        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isAnimating)) { ctx in
            let phase = currentPhase(at: ctx.date)
            let amp = isAnimating ? amplitude : 0

            VStack(alignment: .leading, spacing: gap) {
                ZStack(alignment: .leading) {
                    WavyBar(
                        phase: phase,
                        amplitude: amp,
                        wavelength: wavelength,
                        baseHeight: baseHeight
                    )
                    .fill(Tokens.ink)
                    .frame(width: topWidth, height: rowHeight)

                    Circle()
                        .fill(Tokens.ink)
                        .frame(width: dotDiameter, height: dotDiameter)
                        .offset(x: dotLeading)
                }
                .frame(height: rowHeight)

                WavyBar(
                    phase: phase,
                    amplitude: amp,
                    wavelength: wavelength,
                    baseHeight: baseHeight
                )
                .fill(Tokens.ink)
                .frame(width: middleWidth, height: rowHeight)

                WavyBar(
                    phase: phase,
                    amplitude: amp,
                    wavelength: wavelength,
                    baseHeight: baseHeight
                )
                .fill(Tokens.ink)
                .frame(width: bottomWidth, height: rowHeight)
            }
            .frame(width: middleWidth + dotDiameter, alignment: .leading)
        }
    }

    /// Phase advances negatively over time so the wave pattern travels from
    /// the leading edge toward the trailing edge.
    private func currentPhase(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let normalised = t.truncatingRemainder(dividingBy: cycleSeconds) / cycleSeconds
        return -normalised * 2 * .pi
    }
}

/// A pill-shaped bar whose thickness varies along its length following a
/// sine wave. `phase` shifts the wave horizontally; advancing it negatively
/// over time makes the bulge travel left-to-right. Amplitude tapers to
/// zero at both ends so the wavy interior meets clean semicircular pill
/// caps.
private struct WavyBar: Shape {
    var phase: Double
    var amplitude: CGFloat
    var wavelength: CGFloat
    var baseHeight: CGFloat
    var endTaper: CGFloat = 0.22

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = baseHeight / 2
        let midY = rect.midY
        let leftCenterX = rect.minX + r
        let rightCenterX = rect.maxX - r
        let usableWidth = max(rightCenterX - leftCenterX, 0.0001)
        let stepCount = max(Int(usableWidth.rounded()) * 2, 24)

        func halfThickness(at x: CGFloat) -> CGFloat {
            let local = x - leftCenterX
            let normalised = local / usableWidth
            let taper: CGFloat
            if normalised < endTaper {
                taper = max(0, normalised / endTaper)
            } else if normalised > 1 - endTaper {
                taper = max(0, (1 - normalised) / endTaper)
            } else {
                taper = 1
            }
            let s = sin(2 * .pi * Double(local) / Double(wavelength) + phase)
            return r + amplitude * CGFloat(s) * taper
        }

        // Start of left semicircle (top of cap).
        path.move(to: CGPoint(x: leftCenterX, y: midY - r))

        // Top edge: leading center -> trailing center.
        for i in 1...stepCount {
            let x = leftCenterX + usableWidth * CGFloat(i) / CGFloat(stepCount)
            path.addLine(to: CGPoint(x: x, y: midY - halfThickness(at: x)))
        }

        // Right pill cap.
        path.addArc(
            center: CGPoint(x: rightCenterX, y: midY),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(90),
            clockwise: false
        )

        // Bottom edge: trailing center -> leading center.
        for i in stride(from: stepCount - 1, through: 0, by: -1) {
            let x = leftCenterX + usableWidth * CGFloat(i) / CGFloat(stepCount)
            path.addLine(to: CGPoint(x: x, y: midY + halfThickness(at: x)))
        }

        // Left pill cap, closing the path.
        path.addArc(
            center: CGPoint(x: leftCenterX, y: midY),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(270),
            clockwise: false
        )

        path.closeSubpath()
        return path
    }
}

private struct TurnView: View {
    let turn: ChatTurn
    let resolvedDrafts: [UUID: DraftPreviewCard.Resolution]
    let onConfirm: (ChatDraft) -> Void
    let onCancel: (ChatDraft) -> Void

    var body: some View {
        VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: Space.md) {
            if !turn.text.isEmpty || turn.isStreaming {
                if turn.role == .user {
                    UserBubble(text: turn.text)
                } else {
                    StreamingProse(text: turn.text, isStreaming: turn.isStreaming)
                }
            }

            ForEach(turn.drafts) { draft in
                DraftPreviewCard(
                    draft: draft,
                    resolved: resolvedDrafts[draft.id],
                    onConfirm: { onConfirm(draft) },
                    onEdit: nil,
                    onCancel: { onCancel(draft) }
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

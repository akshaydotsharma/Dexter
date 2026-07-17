import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ChatView: View {
    @State private var viewModel = ChatViewModel()
    #if os(iOS)
    /// The speech transcriber is owned by the app-level `VoiceCaptureViewModel`
    /// and shared via the environment (issue #150). The inline mic button here
    /// and the global press-and-hold overlay therefore drive the SAME single
    /// transcriber instance, which is what keeps the re-entry guard meaningful
    /// (two instances could each install a tap and crash the audio engine).
    ///
    /// iOS-only: voice capture is AVFoundation/Speech-coupled and is gated off
    /// on macOS (issue #281), where Chat is text-only.
    @Environment(VoiceCaptureViewModel.self) private var voiceVM
    private var transcriber: SpeechTranscriber { voiceVM.transcriber }
    #endif
    @State private var pendingViewMore: Bool = false
    @State private var keyboardVisible: Bool = false
    #if os(iOS)
    /// Whatever the user had typed at the moment they tapped the mic.
    /// While recording we replace the input field with `baseline + transcript`
    /// so partials feel live; tapping mic-stop with an empty transcript
    /// restores the baseline so we don't clobber typed text on a misfire.
    @State private var preMicBaseline: String = ""

    /// Tracks an in-progress inline-mic session (issue #151). With the OpenAI
    /// streaming engine the transcript arrives ASYNC, AFTER `stop()` has flipped
    /// `transcriber.isRecording` false (server_vad finalizes ~0.5s after a pause;
    /// a manual stop commits, then the `…completed` lands ~1-2s later). So we
    /// can't gate transcript-mirroring on `isRecording` — that drops the inline
    /// transcript every time. Instead we open this flag when the inline mic
    /// starts and keep it true through the async tail until the final transcript
    /// has landed (observed via `didFinalizeTranscript`) or the session is
    /// superseded by a send / a new mic start. Mirrors the await-the-final
    /// pattern already used in `VoiceCaptureViewModel`.
    @State private var inlineMicActive = false
    /// Baseline value of `transcriber.didFinalizeTranscript` captured when the
    /// inline session starts, so we can tell when a NEW non-empty final lands
    /// during THIS session (vs. a stale bump from a prior one).
    @State private var inlineMicFinalizeBaseline = 0

    /// Silence-finalize timer (issue #150). Each transcript update from the
    /// transcriber resets this; when it fires after `silenceFinalizeDelay` of
    /// no new partials, we stop the mic and leave the transcript in the input
    /// field as editable text (we do NOT auto-submit). Invalidated on stop.
    @State private var silenceTimer: Timer?
    /// How long the user has to stop speaking before we finalize. ~1.8s sits
    /// in the requested 1.5–2s window: long enough to ride out a natural
    /// mid-sentence pause, short enough to feel responsive.
    private let silenceFinalizeDelay: TimeInterval = 1.8
    #endif

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
                // Full-bleed on iOS; keeps the top title-bar inset on macOS so
                // the split view reserves the title-bar region and the sidebar
                // keeps its top inset (issue #283).
                .canvasIgnoresSafeArea()
                // Tap on empty paper background dismisses the keyboard so
                // the floating tab bar comes back into view (issue #48).
                // `hideKeyboard()` is a no-op on macOS (no software keyboard).
                .onTapGesture {
                    hideKeyboard()
                }

            VStack(spacing: 0) {
                // Top bar + body area: any tap dismisses the keyboard.
                // simultaneousGesture fires ALONGSIDE child gestures, so
                // scrolling, tapping messages, and tapping suggestion chips
                // all keep working — they just additionally drop the
                // keyboard. The ChatInputBar is intentionally outside this
                // gesture so tapping the text field still focuses it.
                VStack(spacing: 0) {
                    // iOS renders the in-view top bar; macOS uses the native
                    // window toolbar via `.macSectionChrome` below (issue #283).
                    #if os(iOS)
                    TopBar(
                        title: viewModel.turns.isEmpty ? nil : "Chat",
                        onMenu: {
                            router.openDrawer()
                        }
                    )
                    #endif

                    if viewModel.turns.isEmpty {
                        emptyState
                    } else {
                        conversation
                    }
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        hideKeyboard()
                    }
                )

                #if os(iOS)
                if transcriber.isRecording {
                    ListeningIndicator(onStop: stopListening)
                        .padding(.horizontal, Space.lg)
                        .padding(.bottom, Space.xs)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

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
                #endif

                ChatInputBar(
                    text: $viewModel.draftInput,
                    isSending: viewModel.isSending,
                    onSend: send,
                    onMic: micHandler,
                    isMicActive: micActive,
                    focused: $inputFocused
                )
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.sm)
                // Reserve room for the bottom tab bar so the input bar
                // doesn't hide behind it. When the keyboard is up, the bar
                // hides and the keyboard pushes the input up directly. The
                // gap above the tab bar is intentionally small so the input
                // sits visually close to the floating pill.
                //
                // macOS has no tab bar and no software keyboard, so the input
                // bar sits a modest inset above the window's bottom edge
                // instead of reserving the 74pt tab-bar strip (issue #283).
                #if os(macOS)
                .padding(.bottom, Space.lg)
                #else
                .padding(.bottom, keyboardVisible ? Space.md : BottomTabBarMetrics.height)
                #endif
            }
            // Animate the listening banner and inline mic-error in/out so they
            // don't pop (their transitions are declared at each call site).
            #if os(iOS)
            .animation(.easeOut(duration: 0.2), value: transcriber.isRecording)
            #endif
        }
        .background(Tokens.paper)
        .macSectionChrome("Chat")
        .onAppear {
            // Auto-focusing the input on landing is a phone idiom ("pop the
            // keyboard so the surface is ready to type", issue #48). On macOS
            // it steals first-responder the moment Chat opens, which (a) makes
            // the first click on another sidebar row merely resign focus
            // instead of switching sections — leaving Chat highlighted — and
            // (b) drives a focus-into-a-bottom-field relayout that rides the
            // sidebar up under the traffic lights. So it stays iOS-only (#283).
            #if os(iOS)
            // Land in keyboard-up state on first appearance. The small
            // delay gives SwiftUI time to lay the view tree out before
            // we ask the TextField to take first responder.
            if router.currentSection == .chat {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    inputFocused = true
                }
            }
            #endif
        }
        .onChange(of: router.currentSection) { _, newSection in
            #if os(iOS)
            // Tapping the chat circle from any other surface should drop
            // the user straight into typing (issue #48).
            if newSection == .chat {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    inputFocused = true
                }
            }
            #endif
        }
        #if os(iOS)
        .onChange(of: transcriber.transcript) { _, newTranscript in
            // Mirror live partials into the existing TextField so the user
            // sees the transcription appear in real time. Append to the
            // baseline (whatever was typed before mic-tap) instead of
            // replacing — keeps already-typed context intact.
            //
            // Gated on `inlineMicActive` (NOT `transcriber.isRecording`): with
            // the OpenAI engine the transcript lands AFTER `isRecording` has
            // gone false, so gating on `isRecording` drops the final text every
            // time (issue #151). The inline session stays open through that
            // async tail, so this mirroring still fires when the post-stop
            // transcript arrives.
            //
            // Suppressed while the global voice overlay is presented: the
            // overlay's `VoiceCaptureViewModel` owns the transcript and its
            // own silence timer in that mode, so the inline chat mirroring
            // must stand down to avoid two owners writing the same transcriber.
            guard inlineMicActive, !router.showVoiceOverlay else { return }
            mirrorTranscript(newTranscript)
            // Each new partial is a sign of speech: reset the silence
            // countdown. Once partials stop arriving for `silenceFinalizeDelay`
            // the timer fires and finalizes (issue #150). Only meaningful while
            // the mic is genuinely still recording — the post-stop async tail
            // shouldn't re-arm a finalize timer.
            if transcriber.isRecording { scheduleSilenceFinalize() }
        }
        .onChange(of: transcriber.didFinalizeTranscript) { _, _ in
            // A non-empty authoritative transcript landed. If it belongs to the
            // current inline session (counter advanced past our baseline), make
            // sure it's in the input field, then close the inline session so a
            // later session can't bleed this text in. The overlay path ignores
            // this — it owns the transcriber when presented (issue #151).
            guard inlineMicActive, !router.showVoiceOverlay else { return }
            guard transcriber.didFinalizeTranscript > inlineMicFinalizeBaseline else { return }
            mirrorTranscript(transcriber.transcript)
            // Only close the session once the mic has actually stopped. While
            // it's still recording, server_vad finalizes each pause as its own
            // `…completed`, so closing here would drop every utterance after the
            // first (the mid-session "disappearing" bug). The transcriber
            // accumulates across utterances, so mirroring the running transcript
            // keeps the full text in the field until the user stops (issue #151).
            if !transcriber.isRecording { endInlineMicSession() }
        }
        .onChange(of: transcriber.isRecording) { _, recording in
            // If recording ends for any reason (user tapped stop, an error,
            // or our own finalize), tear the silence timer down so it can't
            // fire against a dead session. We deliberately do NOT end the inline
            // mic session here: the OpenAI final transcript arrives AFTER
            // `isRecording` goes false, and the session must stay open to catch
            // it (issue #151). The session is closed on `didFinalizeTranscript`,
            // on send, or when a new mic session starts.
            if !recording { cancelSilenceTimer() }
        }
        .onDisappear {
            cancelSilenceTimer()
            // Leaving chat ends any inline session so a late async transcript
            // can't write into the field after the user has navigated away.
            endInlineMicSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.18)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.18)) { keyboardVisible = false }
        }
        #endif
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

    /// Mic tap handler passed to `ChatInputBar`. On macOS there is no voice
    /// capture (issue #281), so this is `nil` and `ChatInputBar` renders no
    /// mic button. On iOS it toggles the shared transcriber.
    private var micHandler: (() -> Void)? {
        #if os(iOS)
        return { Task { await toggleMic() } }
        #else
        return nil
        #endif
    }

    /// Whether the mic is actively recording. Always `false` on macOS.
    private var micActive: Bool {
        #if os(iOS)
        return transcriber.isRecording
        #else
        return false
        #endif
    }

    private func send() {
        #if os(iOS)
        // Flush any in-flight transcription first so the final partial
        // lands in `draftInput` before the message ships.
        if transcriber.isRecording {
            stopListening()
        }
        // The user committed to sending whatever's in the field now. End the
        // inline mic session so a still-in-flight async transcript from this
        // session can't land in `draftInput` after the message has shipped
        // (issue #151).
        endInlineMicSession()
        #endif
        Task { await viewModel.send() }
    }

    #if os(iOS)
    private func toggleMic() async {
        if transcriber.isRecording {
            stopListening()
        } else {
            await startListening()
        }
    }

    /// Begin a voice-capture session: drop the keyboard (so the listening UI
    /// owns the surface), snapshot any typed baseline, and start the
    /// transcriber. Shared by the mic button and the press-and-hold entry
    /// point (issue #150). If permission is denied, the transcriber surfaces
    /// the failure through `errorMessage` and the inline error path renders it.
    private func startListening() async {
        guard !transcriber.isRecording else { return }
        // Drop the keyboard so the listening UI owns the surface and the
        // input field shows the live transcript instead of a caret.
        inputFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        // Snapshot what's already in the field so live partials append to it
        // rather than overwriting typed context.
        preMicBaseline = viewModel.draftInput
        // Open the inline mic session BEFORE starting the transcriber. Each
        // `transcriber.start()` resets `transcript` to "" and we re-capture the
        // baseline here, so a fresh session is clean and can't inherit a prior
        // session's text. Baseline the finalize counter so we only react to a
        // NEW non-empty final from this session (issue #151).
        inlineMicActive = true
        inlineMicFinalizeBaseline = transcriber.didFinalizeTranscript
        await transcriber.toggle()
    }

    /// Stop the transcriber and leave the transcript in the input field as
    /// editable text. Deliberately does NOT submit — the user reads/edits and
    /// taps send, or speaks again to append (issue #150).
    ///
    /// Does NOT end the inline mic session: with the OpenAI engine the final
    /// transcript arrives AFTER this returns, so the session must stay open to
    /// catch it (issue #151). It closes on `didFinalizeTranscript`, on send, or
    /// when a new session starts.
    private func stopListening() {
        transcriber.stop()
        cancelSilenceTimer()
    }

    /// Write the live/final transcript into the input field, appended to the
    /// pre-mic baseline so typed context survives. Shared by the partial-
    /// mirroring and the final-landing paths so they stay consistent.
    private func mirrorTranscript(_ text: String) {
        if text.isEmpty {
            viewModel.draftInput = preMicBaseline
        } else if preMicBaseline.isEmpty {
            viewModel.draftInput = text
        } else {
            viewModel.draftInput = preMicBaseline + " " + text
        }
    }

    /// Close the inline mic session so a later session can't inherit this one's
    /// async transcript. Safe to call repeatedly (issue #151).
    private func endInlineMicSession() {
        inlineMicActive = false
    }

    /// (Re)arm the silence-finalize countdown. Called on every transcript
    /// partial; the most recent call wins, so the timer only fires once the
    /// user has been quiet for `silenceFinalizeDelay`. On fire we stop the
    /// mic but keep the transcript editable (no auto-send).
    private func scheduleSilenceFinalize() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: silenceFinalizeDelay,
            repeats: false
        ) { _ in
            Task { @MainActor in
                guard transcriber.isRecording else { return }
                stopListening()
            }
        }
    }

    private func cancelSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
    #endif

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

/// "Listening…" banner shown above the input bar while the transcriber is
/// active (issue #150). A pulsing dot + animated waveform bars read as a live
/// mic state, and tapping anywhere on the row stops listening (mirrors the
/// input-bar stop button so the user has an obvious cancel target right where
/// their eyes are). Uses the restrained design vocabulary: surface fill,
/// paper border, danger-tinted dot to echo the input-bar stop affordance.
///
/// iOS-only: relies on `WaveformBars` and the voice transcriber, both gated
/// off on macOS (issue #281).
#if os(iOS)
private struct ListeningIndicator: View {
    let onStop: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: Space.sm) {
            // Pulsing mic dot — the recording "heartbeat".
            Circle()
                .fill(Tokens.danger)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1.0 : 0.55)
                .opacity(pulse ? 1.0 : 0.5)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }

            Text("Listening…")
                .font(.edCaption)
                .foregroundStyle(Tokens.ink)

            WaveformBars()

            Spacer(minLength: 0)

            Text("Tap to stop")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Tokens.surface,
            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        )
        .paperBorder(Tokens.border, radius: Radius.md)
        .contentShape(Rectangle())
        .onTapGesture { onStop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listening. Tap to stop voice input.")
        .accessibilityAddTraits(.isButton)
    }
}
#endif

/// Three short bars that bob continuously to suggest live audio. Decorative
/// only — height is time-driven, not bound to actual mic levels (the
/// transcriber doesn't expose levels), so it reads as "active" without
/// implying a meter.
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

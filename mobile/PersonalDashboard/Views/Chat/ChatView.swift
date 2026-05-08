import SwiftUI
import UIKit
#if DEBUG || DEKS_DEBUG_TOOLS
import ActivityKit
#endif

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

    #if DEBUG || DEKS_DEBUG_TOOLS
    /// Step-by-step record of the most recent "Test Live Activity" run.
    /// Each line is appended on the main actor so the view re-renders
    /// in real time while the diagnostic flow walks through the
    /// controller's lifecycle. The user can screenshot this list and
    /// share the exact path the code took.
    @State private var diagnosticLog: [String] = []
    /// Latch so the user can't fire two diagnostic runs concurrently —
    /// they'd race over the shared controller state and the log would
    /// interleave noise.
    @State private var diagnosticRunning: Bool = false
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
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Tokens.muted)

                Rectangle()
                    .fill(Tokens.accentChat)
                    .frame(width: 32, height: 2)

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

                #if DEBUG || DEKS_DEBUG_TOOLS
                // Diagnostic: directly drives the Capture Live Activity
                // without going through Shortcuts / Dictate Text. Lets
                // the user see whether the Dynamic Island rendering
                // itself is working in isolation from the Action Button
                // → Shortcut → preflight intent chain.
                //
                // Background the app after tapping; the activity runs
                // for ~25 s in `.processing` (so the three lines should
                // visibly dance), then settles in `.complete` for ~4 s
                // before dismissing.
                //
                // The user-facing log under the button surfaces every
                // step the controller takes — auth check, existing
                // activity count, request outcome, ticker updates — so
                // a screenshot is enough to diagnose which silent return
                // path is firing if the island stays empty.
                VStack(spacing: Space.sm) {
                    Button {
                        runLiveActivityDiagnostic()
                    } label: {
                        HStack(spacing: Space.xs) {
                            Image(systemName: diagnosticRunning ? "hourglass" : "stethoscope")
                                .font(.system(size: 11, weight: .medium))
                            Text(diagnosticRunning ? "Running..." : "Test Live Activity")
                                .font(.edCaption)
                        }
                        .foregroundStyle(Tokens.muted)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, Space.xs)
                        .overlay(
                            Capsule().stroke(Tokens.border.opacity(0.6), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(diagnosticRunning)

                    if !diagnosticLog.isEmpty {
                        LiveActivityDiagnosticPanel(lines: diagnosticLog)
                            .frame(maxWidth: 360)
                    }
                }
                .padding(.top, Space.lg)
                #endif
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

    #if DEBUG || DEKS_DEBUG_TOOLS
    // MARK: - Live Activity diagnostic

    /// Walks the controller through a full lifecycle (force-clear ->
    /// auth check -> request -> tick observation -> end) and surfaces
    /// each step on screen. The activity runs in `.processing` for
    /// ~25 s so the user can background the app and see the Dynamic
    /// Island animate; we then settle into `.complete` for the linger
    /// window before dismissing.
    ///
    /// `Task.detached` so SwiftUI view-task cancellation can't kill the
    /// 25 s hold mid-run (a plain `Task {}` inherits the parent's
    /// cancellation tree, which can drop when the user navigates away).
    /// All state mutation happens via `appendDiagnostic(...)` which
    /// hops to MainActor.
    private func runLiveActivityDiagnostic() {
        guard !diagnosticRunning else { return }
        diagnosticRunning = true
        diagnosticLog = []

        Task.detached {
            let controller = CaptureLiveActivityController.shared
            await appendDiagnostic("[tap] tapped at \(Self.diagnosticTimestamp())")

            // 1. Auth check - we read this BEFORE forceClear so the
            //    "areActivitiesEnabled" line reflects the system state
            //    independent of whether we had stale activities.
            let authEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
            await appendDiagnostic("[auth] areActivitiesEnabled = \(authEnabled)")

            // 2. Snapshot existing activities BEFORE we clear them so
            //    the user sees how many were stuck. The diagnostic is
            //    most useful when this number is non-zero on a fresh
            //    tap — that reveals the early-return path.
            let preExisting = Activity<CaptureActivityAttributes>.activities
            let preStates = preExisting.map { Self.shortStateLabel($0.activityState) }
            await appendDiagnostic("[existing] live activities: \(preExisting.count); states: \(preStates)")

            // 3. Force-clear so start() is guaranteed to take the
            //    spawn path rather than the reattach early-return.
            let cleared = await controller.forceClearStaleActivities()
            await appendDiagnostic("[cleanup] ended \(cleared) stale activities")

            // 4. Install the tick observer BEFORE start() so we don't
            //    miss the first tick. The closure hops to MainActor
            //    inside appendDiagnostic.
            await controller.setOnTickUpdate { count, phase in
                let phaseRounded = String(format: "%.2f", phase)
                Task { await appendDiagnostic("[ticker] update #\(count) phase=\(phaseRounded)") }
            }

            // 5. Request the activity. The outcome enum tells us
            //    exactly which path we took.
            await appendDiagnostic("[request] calling Activity<CaptureActivityAttributes>.request(...)")
            let outcome = await controller.start()
            switch outcome {
            case .skippedAuthDisabled:
                await appendDiagnostic("[request] SKIPPED: areActivitiesEnabled=false")
            case .skippedExistingActivity(let id):
                await appendDiagnostic("[request] SKIPPED: existing activity id=\(id)")
            case .requested(let id):
                await appendDiagnostic("[request] activity id = \(id)")
            case .failed(let error):
                await appendDiagnostic("[request] FAILED: \(error.localizedDescription)")
            }

            // If we never got a live activity, no point waiting 25 s —
            // the user will see the failure path on screen and can
            // act on it. End the diagnostic early.
            let didStart: Bool
            switch outcome {
            case .requested, .skippedExistingActivity: didStart = true
            case .skippedAuthDisabled, .failed: didStart = false
            }
            if !didStart {
                await appendDiagnostic("[end] aborting — no active live activity")
                await controller.setOnTickUpdate(nil)
                await MainActor.run { diagnosticRunning = false }
                return
            }

            // 6. Hold for 25 s in .processing so the user can
            //    background the app and watch the island animate.
            //    The ticker fires at ~500 ms cadence so a few of those
            //    ticks will land in the diagnostic log too.
            try? await Task.sleep(nanoseconds: 25 * 1_000_000_000)

            // 7. Settle.
            await appendDiagnostic("[end] settling to .complete after 25 s")
            await controller.end(state: .complete(summary: "Test"), linger: 4)
            // Linger covers the visible "complete" window. After it
            // expires the system actually clears the slot.
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            await appendDiagnostic("[end] dismissed")
            await MainActor.run { diagnosticRunning = false }
        }
    }

    /// Hop to MainActor and append a single line. Cap at 200 lines so
    /// a runaway tick loop can't blow up the view's render tree.
    @MainActor
    private func appendDiagnostic(_ line: String) {
        diagnosticLog.append(line)
        if diagnosticLog.count > 200 {
            diagnosticLog.removeFirst(diagnosticLog.count - 200)
        }
    }

    private static func diagnosticTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    private static func shortStateLabel(_ state: ActivityState) -> String {
        switch state {
        case .active:    return "active"
        case .ended:     return "ended"
        case .dismissed: return "dismissed"
        case .stale:     return "stale"
        @unknown default: return "unknown"
        }
    }
    #endif
}

#if DEBUG || DEKS_DEBUG_TOOLS
/// Tight monospace panel that renders the diagnostic log under the
/// "Test Live Activity" button. Sized to about 12 lines visible — if
/// the run pushes past that, the panel scrolls.
private struct LiveActivityDiagnosticPanel: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
        .background(
            Tokens.surface,
            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .stroke(Tokens.border.opacity(0.6), lineWidth: 0.5)
        )
    }
}
#endif

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

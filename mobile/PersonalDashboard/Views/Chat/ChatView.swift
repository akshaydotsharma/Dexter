import SwiftUI
import UIKit

struct ChatView: View {
    @State private var viewModel = ChatViewModel()
    @State private var resolvedDrafts: [UUID: DraftPreviewCard.Resolution] = [:]
    @State private var pendingViewMore: Bool = false
    @State private var keyboardVisible: Bool = false

    @Bindable var router: AppRouter
    @Binding var schemePref: ColorSchemePref

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
                            withAnimation(.easeOut(duration: 0.2)) {
                                router.drawerOpen = true
                            }
                        },
                        onToggleTheme: {
                            schemePref = schemePref.next
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

                ChatInputBar(
                    text: $viewModel.draftInput,
                    isSending: viewModel.isSending,
                    onSend: send
                )
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.sm)
                // Reserve room for the bottom tab bar so the input bar
                // doesn't hide behind it. When the keyboard is up, the bar
                // hides and the keyboard pushes the input up directly.
                .padding(.bottom, keyboardVisible ? Space.md : (Space.md + BottomTabBarMetrics.height))
            }
        }
        .background(Tokens.paper)
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
        Task { await viewModel.send() }
    }

    private var hasLiveAssistantTurn: Bool {
        viewModel.turns.last?.isStreaming == true
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

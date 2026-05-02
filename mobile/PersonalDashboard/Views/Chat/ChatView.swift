import SwiftUI

struct ChatView: View {
    @State private var viewModel = ChatViewModel()
    @State private var resolvedDrafts: [Int: DraftPreviewCard.Resolution] = [:]
    @State private var pendingViewMore: Bool = false

    @Bindable var router: AppRouter
    @Binding var schemePref: ColorSchemePref

    private let examples = [
        "Remind me to call John tomorrow at 3",
        "New shopping list with milk, eggs, bread",
        "Note: ideas for Q3 OKRs"
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Tokens.paper.ignoresSafeArea()

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

                ChatInputBar(
                    text: $viewModel.draftInput,
                    isSending: viewModel.isSending,
                    onSend: send
                )
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.sm)
                .padding(.bottom, Space.md)
            }
        }
        .background(Tokens.paper)
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
                                Task {
                                    await viewModel.reject(draft)
                                    resolvedDrafts[draft.id] = .cancelled
                                }
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
    let resolvedDrafts: [Int: DraftPreviewCard.Resolution]
    let onConfirm: (Draft) -> Void
    let onCancel: (Draft) -> Void

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

import SwiftUI

/// The conversation that helps decide what to eat, at the top of the Plan tab
/// (#599).
///
/// ### Why it is inline and not a sheet
///
/// It started as a sheet off a button, and that was wrong for one reason: this
/// chat is ABOUT the day underneath it. A sheet covers the thing being
/// discussed, so every answer had to restate what the plan already showed, and
/// adding a suggestion meant dismissing the sheet to find out where it landed.
/// Inline, the cards and the tiles are on one page — you add a meal and watch
/// the tile fill in.
///
/// It also stops the chat being a place you have to decide to go to. A panel at
/// the top of an empty day is an invitation; a button is a question.
///
/// ### Why it has no scroll view of its own
///
/// It is a block in the tab's page scroll, so the turns grow the page rather
/// than filling a fixed box with a second scrollbar inside the first. Nested
/// scrolling is unpleasant on a trackpad and ambiguous on a phone, and a chat
/// that is three exchanges long does not need its own viewport. The page scrolls
/// to the newest turn, which the tab owns because the tab owns the scroll.
///
/// ### It writes nothing by itself
///
/// The model has one tool and that tool proposes. `onAdd` is the ONLY path from
/// here to the store, and it fires on a tap. See `MealPlanAdvisor`.
struct MealPlanChatPanel: View {

    @Bindable var model: MealPlanChatModel

    /// How the Add button names the day: "today", "tomorrow", "Thursday 18 Sep".
    let dayLabel: String
    /// True when targets are set, for the opener's one-line summary.
    let hasTargets: Bool
    /// True when anything at all has been logged, same reason.
    let hasHistory: Bool
    /// True when the day in view already holds blocks.
    let hasPlan: Bool

    var onSend: () -> Void
    var onAdd: (MealPlanSuggestion) -> Void

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header
            if model.isEmpty {
                opener
            } else {
                transcript
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            inputRow
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.mutedSoft)
            Text("What should I eat?").eyebrow()
            Spacer(minLength: 0)
            if !model.isEmpty {
                Button {
                    model.reset()
                } label: {
                    Text("Clear")
                        .font(.edCaption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.muted)
                .accessibilityLabel("Clear this conversation")
            }
        }
    }

    // MARK: - The empty state

    /// What the chat knows, said plainly, and three ways in.
    ///
    /// Stating the context is not decoration. A chat that silently knows your
    /// targets and your last fortnight reads as a generic assistant until it
    /// proves otherwise, and the first question is the one most likely to be
    /// wasted asking something it could already answer.
    private var opener: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(openerBody)
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)

            ChipFlowLayout(spacing: Space.sm) {
                ForEach(Self.examples, id: \.self) { example in
                    ExampleChip(text: example) {
                        model.draftInput = example
                        onSend()
                    }
                }
            }
        }
    }

    private var openerBody: String {
        var parts: [String] = []
        parts.append(hasTargets
            ? "Knows your daily targets"
            : "You have not set targets yet, so suggestions go on taste and habit")
        parts.append(hasHistory
            ? "and what you logged over the last fortnight."
            : "and nothing is logged yet, so say what you usually eat.")
        parts.append(hasPlan
            ? "It can see what is already planned for \(dayLabel)."
            : "Nothing is planned for \(dayLabel) yet.")
        parts.append("Nothing is added until you tap Add.")
        return parts.joined(separator: " ")
    }

    private static let examples = [
        "What should I have for dinner?",
        "Something high in protein and quick",
        "Plan the rest of this day"
    ]

    // MARK: - Turns

    private var transcript: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ForEach(model.turns) { turn in
                turnView(turn)
                    .id(turn.id)
            }
        }
    }

    @ViewBuilder
    private func turnView(_ turn: MealPlanChatTurn) -> some View {
        switch turn.role {
        case .user:
            UserBubble(text: turn.text)
        case .assistant:
            VStack(alignment: .leading, spacing: Space.md) {
                if turn.text.isEmpty && turn.isStreaming {
                    TypingIndicator()
                } else {
                    AIProse(text: turn.text)
                }
                ForEach(turn.suggestions) { suggestion in
                    MealPlanSuggestionCard(
                        suggestion: suggestion,
                        dayLabel: dayLabel,
                        wasAdded: model.wasAdded(suggestion),
                        onAdd: { onAdd(suggestion) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(spacing: Space.sm) {
            ChatInputBar(
                text: $model.draftInput,
                isSending: model.isSending,
                onSend: onSend,
                focused: $inputFocused
            )
            if model.isSending {
                Button {
                    model.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(EdIconButtonStyle(tint: Tokens.danger))
                .accessibilityLabel("Stop")
            }
        }
    }
}

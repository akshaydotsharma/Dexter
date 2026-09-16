import SwiftUI

/// The conversation that helps decide what to eat (#599).
///
/// ### Where it lives, and why it moved twice
///
/// It began as a sheet off a button, which covered the thing being discussed: a
/// full-screen sheet meant every answer had to restate what the plan already
/// showed, and adding a suggestion meant dismissing it to find out where the
/// meal landed.
///
/// Then it sat inline at the top of the tab, which fixed that and cost something
/// else: the plan is the content, and a chat above it pushed four tiles and a
/// calendar below the fold on every visit, whether or not anybody wanted to
/// talk.
///
/// It is now the body of `MealPlanChatOverlay` — a floating button at the bottom
/// right and a local panel over the corner of the plan. That keeps the plan
/// whole AND keeps it visible behind the conversation, which is the property the
/// sheet lost and the inline panel paid too much for.
///
/// ### Why it has no scroll view of its own
///
/// The overlay owns the scrolling, so this is a plain column. The turns and the
/// opener are the same in either container, which is why this view survived both
/// moves unchanged.
///
/// ### It writes nothing by itself
///
/// The model has one tool and that tool proposes. `onAdd` is the ONLY path from
/// here to the store, and it fires on a tap, with the day and the meal the card
/// was set to. See `MealPlanAdvisor`.
struct MealPlanChatPanel: View {

    @Bindable var model: MealPlanChatModel

    /// The day a suggestion's picker starts on: whatever the calendar is
    /// showing. The card can be pointed anywhere; this is only the default.
    let defaultDay: Date
    /// How the opener names that day: "today", "tomorrow", "Thursday 18 Sep".
    let dayLabel: String
    /// True when targets are set, for the opener's one-line summary.
    let hasTargets: Bool
    /// True when anything at all has been logged, same reason.
    let hasHistory: Bool
    /// True when the day in view already holds blocks.
    let hasPlan: Bool

    var onSend: () -> Void
    var onAdd: (MealPlanSuggestion, Date, MealType) -> Void

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        defaultDay: defaultDay,
                        wasAdded: model.wasAdded(suggestion),
                        onAdd: { day, mealType in onAdd(suggestion, day, mealType) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

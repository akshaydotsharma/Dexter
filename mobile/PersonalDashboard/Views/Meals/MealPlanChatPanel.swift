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
/// The container owns the scrolling, so this is a plain column of turns. That is
/// all it is now: the explainer and the three example prompts came off on
/// request, because a chat that opens onto a paragraph about itself is a chat
/// you have to get past before you can type. An empty conversation is empty, the
/// caret is already in the field, and the first thing on screen is your own
/// question.
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
    var onAdd: (MealPlanSuggestion, Date, MealType) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            transcript
            if let error = model.errorMessage {
                Text(error)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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

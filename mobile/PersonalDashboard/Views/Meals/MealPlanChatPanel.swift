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
            VStack(alignment: .trailing, spacing: Space.xs) {
                if !turn.photos.isEmpty {
                    SentPhotoRow(photos: turn.photos)
                }
                // A photograph sent with nothing typed draws no bubble. The
                // request carries a neutral line so the API has a text block
                // (`MealPlanAdvisor.photoOnlyInput`), but putting words the user
                // never wrote into their own bubble would be the transcript
                // telling them what they said (#631).
                if !turn.text.isEmpty {
                    UserBubble(text: turn.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: Space.md) {
                if turn.text.isEmpty && turn.isStreaming {
                    TypingIndicator()
                } else {
                    AIProse(text: turn.text)
                }
                // Under the prose rather than under the cards: the figures the
                // sources back up are in the sentence just above, and a turn
                // that looked something up usually proposes no card at all
                // (#647). Reuses the block the meal detail sheet draws, so a
                // citation looks the same wherever the app makes one.
                MealSourcesBlock(sources: turn.sources)
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

/// The photographs on a turn that has already been sent (#631).
///
/// Read-only, unlike `MealPhotoStrip`: a sent message cannot have an attachment
/// removed from it, and a remove button here would offer to edit history. It is
/// still tappable, because "was that the right picture" is a question you ask
/// AFTER reading the answer, and 44pt cannot settle it.
private struct SentPhotoRow: View {

    let photos: [MealPhoto]

    @State private var viewing: MealPhoto?

    private let side: CGFloat = 44

    var body: some View {
        HStack(spacing: Space.xs) {
            Spacer(minLength: 0)
            ForEach(photos) { photo in
                thumbnail(photo)
            }
        }
        .sheet(item: $viewing) { photo in
            MealPhotoViewer(photo: photo)
        }
    }

    @ViewBuilder
    private func thumbnail(_ photo: MealPhoto) -> some View {
        let image = PlatformImage(data: photo.jpegData)
        Button {
            if image != nil { viewing = photo }
        } label: {
            Group {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Tokens.surface2
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 14))
                                .foregroundStyle(Tokens.mutedSoft)
                        )
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.sm)
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(image == nil)
        .accessibilityLabel("Photo sent with this message")
        .accessibilityHint(image == nil ? "" : "Opens it full size")
    }
}

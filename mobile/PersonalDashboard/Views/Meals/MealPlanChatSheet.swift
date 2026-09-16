import SwiftUI

/// The conversation that helps decide what to eat (#599).
///
/// ### Why it is a sheet over the Plan tab and not a fifth tab
///
/// You arrive at it FROM a day and you leave it having put something on that
/// day. A tab is somewhere you settle; this is a detour with a destination, and
/// the destination is the calendar underneath it. Putting it in a tab would also
/// separate it from the day it is talking about, and the day is most of what it
/// knows.
///
/// ### Why it is not the main Chat surface
///
/// That one writes. It holds 28 tools and auto-executes the non-destructive
/// ones, which is right for capture and wrong here: every day this chat talks
/// about is a day that has not happened, and a model that could fill the
/// calendar would fill days the user was only thinking out loud about. This
/// surface has one tool and it proposes. See `MealPlanAdvisor`.
///
/// ### The conversation outlives the sheet, not the section
///
/// The model is owned by `MealPlanView`, so closing this to look at the calendar
/// and reopening it keeps the thread. Leaving Meals altogether ends it, the same
/// call the main chat surface makes: what gets kept from a plan conversation is
/// the block it produced, and that is on the calendar.
struct MealPlanChatSheet: View {

    @Bindable var model: MealPlanChatModel

    /// The day suggestions are added to, and the day the context describes.
    let day: Date
    /// How the Add button names that day: "Thursday", "today".
    let dayLabel: String
    /// The targets in force on `day`, or nil.
    let targets: MealTargets?
    /// Every logged meal, handed down from the section's own query so this
    /// surface does not declare a second one (#442).
    let loggedMeals: [LocalMeal]
    /// What is already planned on `day`.
    let plan: MealPlanDay

    /// Called after a suggestion has been written, so the section can react.
    /// The write itself happens here, through the service.
    var onAdded: (MealPlanSuggestion) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool

    private var service: MealPlanService { .default() }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.canvasIgnoresSafeArea()

                VStack(spacing: 0) {
                    transcript
                    inputBar
                }
            }
            .navigationTitle("What should I eat?")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.reset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .disabled(model.isEmpty)
                    .accessibilityLabel("Start a new conversation")
                }
            }
        }
        #if os(macOS)
        // A macOS sheet with no explicit size collapses to its toolbar (#474).
        // On a phone this minWidth is wider than the screen, so it stays out of
        // the iOS tree entirely.
        .frame(minWidth: 520, idealWidth: 580, minHeight: 600, idealHeight: 760)
        #endif
        .onAppear { inputFocused = true }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if model.isEmpty {
                        opener
                    }
                    ForEach(model.turns) { turn in
                        turnView(turn)
                            .id(turn.id)
                    }
                    if let error = model.errorMessage {
                        Text(error)
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // A zero-height anchor at the very bottom. Scrolling to the
                    // last TURN stops short once that turn is taller than the
                    // viewport, which is exactly when a streaming reply is
                    // growing and the user most needs to see the end of it.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(Space.lg)
            }
            .onChange(of: model.turns.last?.text) { _, _ in scrollToBottom(proxy) }
            .onChange(of: model.turns.count) { _, _ in scrollToBottom(proxy) }
        }
    }

    private static let bottomAnchor = "meal-plan-chat-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: - The empty state

    /// What the chat knows, said plainly, and three ways in.
    ///
    /// Stating the context is not decoration. A chat that silently knows your
    /// targets and your last fortnight reads as a generic assistant until it
    /// proves otherwise, and the user's first question is the one most likely to
    /// be wasted on something it could already answer.
    private var opener: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Ask about \(dayLabel)").eyebrow()
            Text(openerBody)
                .font(.edSubheadline)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)

            ChipFlowLayout(spacing: Space.sm) {
                ForEach(Self.examples, id: \.self) { example in
                    ExampleChip(text: example) {
                        model.draftInput = example
                        send()
                    }
                }
            }
        }
    }

    private var openerBody: String {
        var parts: [String] = []
        parts.append(targets == nil
            ? "You have not set targets yet, so suggestions go on taste and habit."
            : "It knows your daily targets.")
        parts.append(loggedMeals.isEmpty
            ? "Nothing is logged yet, so tell it what you usually eat."
            : "It has read what you logged over the last fortnight.")
        parts.append(plan.isEmpty
            ? "Nothing is planned for this day yet."
            : "It can see what is already planned for this day.")
        parts.append("Nothing it suggests is added until you tap Add.")
        return parts.joined(separator: " ")
    }

    private static let examples = [
        "What should I have for dinner?",
        "Something high in protein and quick",
        "Plan the rest of this day for me"
    ]

    // MARK: - One turn

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
                        onAdd: { add(suggestion) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Tokens.divider)
                .frame(height: 0.5)

            HStack(spacing: Space.sm) {
                ChatInputBar(
                    text: $model.draftInput,
                    isSending: model.isSending,
                    onSend: send,
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
            .padding(Space.md)
        }
        .background(Tokens.surface)
    }

    // MARK: - Actions

    /// Build the context afresh on every send.
    ///
    /// Not cached, and that is the point: the user can add a suggestion, close
    /// the sheet, change the plan and come back, and the next turn has to be
    /// told about the day as it is now rather than as it was when the sheet
    /// opened. It is arithmetic over arrays that are already in memory, so it
    /// costs nothing to rebuild.
    private func send() {
        model.send(
            context: MealPlanContext.build(
                day: day,
                targets: targets,
                loggedMeals: loggedMeals,
                planForDay: plan
            ),
            defaultMealType: MealEstimationService.inferredType(at: Date())
        )
    }

    /// Write a suggestion onto the day.
    ///
    /// The `why` is deliberately NOT carried across. It is an argument for a
    /// choice, and once the choice is made it stops being true of the plan: a
    /// block reading "you are short on protein today" a week later is a note
    /// about a day that has been and gone. The prep note IS carried, because
    /// soaking the beans is still true on the night.
    private func add(_ suggestion: MealPlanSuggestion) {
        do {
            try service.addEntry(
                date: day,
                mealType: suggestion.mealType,
                title: suggestion.title,
                ingredients: suggestion.ingredients,
                notes: suggestion.prepNote,
                status: .planned,
                nutrients: suggestion.nutrients,
                source: MealPlanSource.chat
            )
            // Marked only after the write succeeded. A card reading "Added" over
            // a write that threw is worse than one that can be tapped twice.
            model.markAdded(suggestion)
            onAdded(suggestion)
            Haptics.light()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

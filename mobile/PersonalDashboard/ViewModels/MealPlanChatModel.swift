import Foundation
import Observation

/// One turn in the plan conversation (#599).
struct MealPlanChatTurn: Identifiable, Equatable {
    let id: UUID
    let role: Role
    var text: String
    /// The cards this turn put forward. Empty on a turn that only answered a
    /// question, which is most of them.
    var suggestions: [MealPlanSuggestion]
    /// The photographs the user sent with this turn (#631). Always empty on an
    /// assistant turn.
    ///
    /// Held on the turn rather than only in the request so the transcript still
    /// shows what was asked about. A conversation whose second question is
    /// "what about a vegetarian one" reads as a non sequitur if the picture it
    /// refers to left the screen the moment it was sent.
    var photos: [MealPhoto]
    /// The pages this turn's web searches returned (#647). Empty on every turn
    /// that did not search, which is most of them.
    ///
    /// Held on the turn rather than on the conversation so a later answer from
    /// knowledge cannot inherit an earlier answer's citations. A source line
    /// under a figure that was never looked up is the one failure this feature
    /// must not have.
    var sources: [WebSearchSource]
    /// True while the model is still writing this turn.
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        suggestions: [MealPlanSuggestion] = [],
        photos: [MealPhoto] = [],
        sources: [WebSearchSource] = [],
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.suggestions = suggestions
        self.photos = photos
        self.sources = sources
        self.isStreaming = isStreaming
    }

    enum Role: Hashable {
        case user
        case assistant
    }
}

/// State for the plan chat (#599).
///
/// ### The conversation is not persisted
///
/// Turns live here and die with the session, the same call the main chat
/// surface makes. A plan conversation is a way of arriving at a decision, and
/// the decision is what gets kept: it lands on the calendar as a block, which
/// IS persisted, synced and backed up. Keeping the transcript too would store
/// the reasoning behind every meal forever and make the Plan tab something to
/// tidy up.
///
/// The model is held by the Meals section rather than by the sheet, so closing
/// the sheet to look at the calendar and reopening it does not throw the
/// conversation away. It does not survive leaving the section — see the note on
/// `MealPlanView`.
///
/// ### What it never does
///
/// It does not write to the plan. `addedSuggestionIDs` records what the USER
/// added, purely so a card can stop offering a button it has already had
/// pressed; the write itself is the view's, through `MealPlanService`. Nothing
/// on this type touches SwiftData.
@Observable
@MainActor
final class MealPlanChatModel {

    private(set) var turns: [MealPlanChatTurn] = []
    private(set) var isSending = false
    var draftInput: String = ""

    /// Photographs attached to the message being composed (#631).
    ///
    /// The same lifetime rule `MealPhoto` states: they are an input, not a
    /// record. They move onto the user's turn when the message is sent, and
    /// they go with the conversation when it is reset. Nothing here reaches
    /// SwiftData, and nothing is written to disk.
    var draftPhotos: [MealPhoto] = []

    var errorMessage: String?

    /// Suggestions the user has already added to the plan, by suggestion id.
    ///
    /// Held here rather than on the suggestion itself so the value type stays
    /// immutable and so re-rendering a turn cannot lose the fact. Cleared with
    /// the conversation.
    private(set) var addedSuggestionIDs: Set<UUID> = []

    private let advisor: MealPlanAdvisor
    private var streamTask: Task<Void, Never>?

    /// The advisor is optional rather than defaulted to `MealPlanAdvisor()` in
    /// the signature. A default argument is evaluated in a NONISOLATED context,
    /// and that type is `@MainActor`, so the tidier spelling does not compile.
    /// `ChatViewModel` takes its dependencies the same way for the same reason.
    init(advisor: MealPlanAdvisor? = nil) {
        self.advisor = advisor ?? MealPlanAdvisor()
    }

    var isEmpty: Bool { turns.isEmpty }

    /// True once the user has added this suggestion to a day.
    func wasAdded(_ suggestion: MealPlanSuggestion) -> Bool {
        addedSuggestionIDs.contains(suggestion.id)
    }

    /// Record that the user added a card. The view calls this AFTER the write
    /// succeeded, never before: a card that reads "Added" over a write that
    /// threw is worse than one that can be tapped twice.
    func markAdded(_ suggestion: MealPlanSuggestion) {
        addedSuggestionIDs.insert(suggestion.id)
    }

    /// Throw the conversation away and start again.
    func reset() {
        streamTask?.cancel()
        streamTask = nil
        turns = []
        addedSuggestionIDs = []
        draftPhotos = []
        errorMessage = nil
        isSending = false
    }

    /// Stop the turn in flight, keeping whatever prose has already landed.
    ///
    /// Cancelling terminates the stream, which cancels the underlying URL task
    /// through `continuation.onTermination`. The partial assistant turn stays on
    /// screen rather than vanishing: the user stopped it, so they know why it is
    /// short, and deleting text they were reading would be the ruder answer.
    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        isSending = false
        if let index = turns.indices.last, turns[index].isStreaming {
            turns[index].isStreaming = false
            if turns[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                turns.remove(at: index)
            }
        }
    }

    /// Send one message.
    ///
    /// - Parameters:
    ///   - context: the context block, built by the view from its live queries.
    ///     Passed in rather than built here for the reason `MealPlanContext` is
    ///     a free function over arrays: this type would otherwise need a
    ///     `ModelContext` to do its job, and the interesting half of the feature
    ///     would stop being testable without one.
    ///   - defaultMealType: the part of the day a suggestion falls back to when
    ///     the model names none.
    func send(context: String, defaultMealType: MealType) {
        let trimmed = draftInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // A photograph with no words is a complete message. See
        // `MealPlanAdvisor.photoOnlyInput` for what the request says in that
        // case, and why the turn on screen still shows only the picture.
        let photos = draftPhotos
        guard !trimmed.isEmpty || !photos.isEmpty, !isSending else { return }

        draftInput = ""
        draftPhotos = []
        errorMessage = nil
        isSending = true

        // Taken BEFORE the new turns are appended, so the model is not handed
        // the message it is about to be asked about twice.
        let history = turns
            .filter { !$0.isStreaming }
            .map {
                MealPlanAdvisor.PriorTurn(
                    role: $0.role == .user ? "user" : "assistant",
                    text: $0.text,
                    photos: $0.photos
                )
            }

        turns.append(MealPlanChatTurn(role: .user, text: trimmed, photos: photos))
        let replyIndex = turns.count
        turns.append(MealPlanChatTurn(role: .assistant, text: "", isStreaming: true))

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in advisor.run(
                    history: history,
                    input: trimmed,
                    photos: photos,
                    context: context,
                    defaultMealType: defaultMealType
                ) {
                    // The index is re-checked on every event rather than
                    // captured once. `reset()` can empty the array while a turn
                    // is in flight, and a stale index into an emptied array is a
                    // crash rather than a wrong pixel.
                    guard turns.indices.contains(replyIndex) else { return }
                    switch event {
                    case .textChunk(let chunk):
                        turns[replyIndex].text += chunk
                    case .suggestion(let suggestion):
                        turns[replyIndex].suggestions.append(suggestion)
                    case .sources(let sources):
                        turns[replyIndex].sources = sources
                    case .truncated:
                        turns[replyIndex].text += turns[replyIndex].text.isEmpty
                            ? Self.truncatedMessage
                            : "\n\n" + Self.truncatedMessage
                    case .done:
                        break
                    case .error(let message):
                        errorMessage = message
                    }
                }
                finish(at: replyIndex)
            } catch is CancellationError {
                // `cancel()` has already tidied up.
            } catch {
                finish(at: replyIndex)
                errorMessage = Self.message(for: error)
                // A turn that produced nothing but an error leaves no empty
                // bubble behind: the error banner is the whole of what happened.
                if turns.indices.contains(replyIndex),
                   turns[replyIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   turns[replyIndex].suggestions.isEmpty {
                    turns.remove(at: replyIndex)
                }
                // Only the assistant's empty turn is removed above. The user's
                // turn stays, photographs and all, so a failed send can be read
                // and asked again rather than vanishing with its picture.
            }
        }
    }

    private func finish(at index: Int) {
        isSending = false
        streamTask = nil
        guard turns.indices.contains(index) else { return }
        turns[index].isStreaming = false
    }

    static let truncatedMessage =
        "That answer ran long and got cut off. Ask for fewer options, or ask again more narrowly."

    /// The sentence shown when a turn fails.
    ///
    /// The missing-key case is named specifically because it is the one failure
    /// the user can actually do something about, and "The operation could not be
    /// completed" tells them nothing.
    static func message(for error: Error) -> String {
        if case AnthropicError.notConfigured = error {
            return "No Anthropic API key is set, so the plan chat cannot run. Add one in Settings."
        }
        return error.localizedDescription
    }
}

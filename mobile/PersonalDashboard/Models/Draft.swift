import Foundation

enum DraftActionType: String, Codable, Hashable, Sendable {
    case createTodo = "CREATE_TODO"
    case createNote = "CREATE_NOTE"
    case createList = "CREATE_LIST"
    case updateTodo = "UPDATE_TODO"
    case completeTodo = "COMPLETE_TODO"
    case updateNote = "UPDATE_NOTE"
    case appendToNote = "APPEND_TO_NOTE"
    case updateList = "UPDATE_LIST"
    case addToList = "ADD_TO_LIST"
    case updateListItem = "UPDATE_LIST_ITEM"
    case removeListItem = "REMOVE_LIST_ITEM"
    case updateFolder = "UPDATE_FOLDER"
    case deleteTodo = "DELETE_TODO"
    case deleteNote = "DELETE_NOTE"
    case deleteList = "DELETE_LIST"
    case deleteFolder = "DELETE_FOLDER"
    case createTrip = "CREATE_TRIP"
    case addItineraryItems = "ADD_ITINERARY_ITEMS"
    case updateTrip = "UPDATE_TRIP"
    case deleteTrip = "DELETE_TRIP"
    case updateItineraryItem = "UPDATE_ITINERARY_ITEM"
    case deleteItineraryItem = "DELETE_ITINERARY_ITEM"
    case addExpense = "ADD_EXPENSE"
    case addRecurringExpense = "ADD_RECURRING_EXPENSE"
    case clearExpenses = "CLEAR_EXPENSES"
    case logMeal = "LOG_MEAL"
    case updateMeal = "UPDATE_MEAL"
    case deleteMeal = "DELETE_MEAL"
    case unknown = "UNKNOWN"
}

extension DraftActionType {
    /// This action is held back in CHAT until the user taps Confirm.
    ///
    /// The 2026-07-25 decision was "confirm destructive only": chat
    /// auto-executes add and update with no extra tap, and asks before a
    /// delete. #546 is the first surface to implement it, so the only case that
    /// returns true today is `deleteMeal`. Widening it to the other seven
    /// delete tools changes the behaviour of shipped surfaces and belongs in
    /// its own ticket rather than riding along here.
    ///
    /// ### This is a CHAT gate, never a dispatcher gate
    ///
    /// `ExecuteDraftAction` deliberately knows nothing about it. The
    /// Capture / Shortcut path must keep executing destructive tools directly —
    /// a one-shot Shortcut that cannot delete is a Shortcut that sends you to
    /// the app, which defeats the point of having one — so the check lives at
    /// the chat orchestration layer, where only chat can see it.
    var requiresChatConfirmation: Bool {
        self == .deleteMeal
    }
}

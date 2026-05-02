import Foundation

enum DraftActionType: String, Codable, Hashable, Sendable {
    case createTodo = "CREATE_TODO"
    case createNote = "CREATE_NOTE"
    case createList = "CREATE_LIST"
    case updateTodo = "UPDATE_TODO"
    case completeTodo = "COMPLETE_TODO"
    case updateNote = "UPDATE_NOTE"
    case updateList = "UPDATE_LIST"
    case addToList = "ADD_TO_LIST"
    case updateListItem = "UPDATE_LIST_ITEM"
    case removeListItem = "REMOVE_LIST_ITEM"
    case updateFolder = "UPDATE_FOLDER"
    case deleteTodo = "DELETE_TODO"
    case deleteNote = "DELETE_NOTE"
    case deleteList = "DELETE_LIST"
    case deleteFolder = "DELETE_FOLDER"
    case unknown = "UNKNOWN"
}

struct DraftPayload: Codable, Hashable, Sendable {
    var id: Int?
    var listId: Int?
    var itemIndex: Int?
    var title: String?
    var content: String?
    var description: String?
    var dueDate: Date?
    var tag: String?
    var folderId: Int?
    var name: String?
    var items: [ChecklistItem]?
    var newItems: [ChecklistItem]?
    var text: String?
    var checked: Bool?
    var completed: Bool?
}

struct Draft: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let actionType: DraftActionType
    let draftData: DraftPayload
    let preview: String?
    let status: String?

    // The server's draft serializer emits the payload under `data`, but the
    // Swift property is named `draftData` for clarity. Explicit CodingKeys
    // map the two; the rest stay on the snake_case → camelCase strategy
    // configured on `APIClient.decoder`.
    enum CodingKeys: String, CodingKey {
        case id
        case actionType
        case draftData = "data"
        case preview
        case status
    }
}

struct ChatRequest: Encodable {
    let input: String
    let sessionId: String?
    let timezone: String?
}

struct ChatResponse: Decodable {
    let success: Bool
    let assistantText: String?
    let drafts: [Draft]
    let followUpQuestion: String?
    let errors: [String]?
}

struct ExecuteDraftRequest: Encodable {
    let draftId: Int
    let updatedData: DraftPayload?
}

struct ExecuteDraftResponse: Decodable {
    let success: Bool
    let message: String?
    let draftId: Int?
}

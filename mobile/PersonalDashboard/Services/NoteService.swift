import Foundation

struct NoteService: Sendable {
    let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    // Folders
    func listFolders() async throws -> [NoteFolder] {
        try await api.get("note-folders")
    }

    func createFolder(name: String) async throws -> NoteFolder {
        try await api.post("note-folders", body: NoteFolderCreateRequest(name: name))
    }

    func renameFolder(id: Int, name: String) async throws -> NoteFolder {
        try await api.put("note-folders/\(id)", body: NoteFolderCreateRequest(name: name))
    }

    func deleteFolder(id: Int) async throws {
        try await api.delete("note-folders/\(id)")
    }

    // Notes
    func list(folderId: Int? = nil) async throws -> [Note] {
        let query = folderId.map { [URLQueryItem(name: "folder_id", value: String($0))] } ?? []
        return try await api.get("notes", query: query)
    }

    func create(_ request: NoteCreateRequest) async throws -> Note {
        try await api.post("notes", body: request)
    }

    func update(id: Int, _ request: NoteUpdateRequest) async throws -> Note {
        try await api.put("notes/\(id)", body: request)
    }

    func delete(id: Int) async throws {
        try await api.delete("notes/\(id)")
    }
}

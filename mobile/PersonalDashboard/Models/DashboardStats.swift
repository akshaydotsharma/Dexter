import Foundation

struct DashboardStats: Codable, Hashable, Sendable {
    let todos: StatBlock
    let notes: StatBlock
    let lists: StatBlock

    struct StatBlock: Codable, Hashable, Sendable {
        let total: Int
        let trend: Int
    }
}

struct DashboardConfig: Codable, Hashable, Sendable {
    let id: Int?
    let layoutPreference: LayoutPreference?

    struct LayoutPreference: Codable, Hashable, Sendable {
        let widgets: [String]
    }
}

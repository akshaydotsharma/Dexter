import Foundation

struct DashboardService: Sendable {
    let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    func stats() async throws -> DashboardStats {
        try await api.get("stats")
    }

    func config() async throws -> DashboardConfig {
        try await api.get("config")
    }
}

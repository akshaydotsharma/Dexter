import Foundation
import Observation

@Observable
@MainActor
final class DashboardViewModel {
    private(set) var stats: DashboardStats?
    private(set) var isLoading = false
    var errorMessage: String?

    private let service: DashboardService

    init(service: DashboardService = DashboardService()) {
        self.service = service
        if let cached = CacheStore.load(DashboardStats.self, from: .dashboardStats) {
            self.stats = cached
        }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let fresh = try await service.stats()
            stats = fresh
            CacheStore.save(fresh, to: .dashboardStats)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

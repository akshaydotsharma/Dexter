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
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            stats = try await service.stats()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

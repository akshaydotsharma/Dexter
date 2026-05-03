import Foundation
import Observation

@Observable
@MainActor
final class DashboardViewModel {
    private(set) var stats: DashboardStats?

    private let service: DashboardService

    init() {
        let service = DashboardService()
        self.service = service
        self.stats = service.stats()
    }

    init(service: DashboardService) {
        self.service = service
        self.stats = service.stats()
    }

    func refresh() {
        stats = service.stats()
    }
}

import Foundation
import SwiftData

/// Computes dashboard stats locally from SwiftData. Replaces the previous
/// `GET /api/stats` call so the card works with the Mac dev server off.
///
/// `total` matches the server semantics: count of non-deleted entities.
/// `trend` matches the server formula: ((thisWeek - lastWeek) / lastWeek) * 100,
/// rounded; if lastWeek is 0, returns 100 when thisWeek > 0 else 0. "This week"
/// is the last 7 days; "last week" is days 7-14 ago, both keyed off `createdAt`.
@MainActor
struct DashboardService: Sendable {
    let context: ModelContext

    init() {
        self.context = SwiftDataStore.shared.context
    }

    init(context: ModelContext) {
        self.context = context
    }

    func stats() -> DashboardStats {
        let now = Date()
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now

        let todoTotal = (try? context.fetchCount(FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.deletedAt == nil }
        ))) ?? 0
        let todoThisWeek = (try? context.fetchCount(FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.deletedAt == nil && $0.createdAt >= weekAgo }
        ))) ?? 0
        let todoLastWeek = (try? context.fetchCount(FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.deletedAt == nil && $0.createdAt >= twoWeeksAgo && $0.createdAt < weekAgo }
        ))) ?? 0

        let noteTotal = (try? context.fetchCount(FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.deletedAt == nil }
        ))) ?? 0
        let noteThisWeek = (try? context.fetchCount(FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.deletedAt == nil && $0.createdAt >= weekAgo }
        ))) ?? 0
        let noteLastWeek = (try? context.fetchCount(FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.deletedAt == nil && $0.createdAt >= twoWeeksAgo && $0.createdAt < weekAgo }
        ))) ?? 0

        let listTotal = (try? context.fetchCount(FetchDescriptor<LocalList>(
            predicate: #Predicate { $0.deletedAt == nil }
        ))) ?? 0
        let listThisWeek = (try? context.fetchCount(FetchDescriptor<LocalList>(
            predicate: #Predicate { $0.deletedAt == nil && $0.createdAt >= weekAgo }
        ))) ?? 0
        let listLastWeek = (try? context.fetchCount(FetchDescriptor<LocalList>(
            predicate: #Predicate { $0.deletedAt == nil && $0.createdAt >= twoWeeksAgo && $0.createdAt < weekAgo }
        ))) ?? 0

        return DashboardStats(
            todos: .init(total: todoTotal, trend: trend(thisWeek: todoThisWeek, lastWeek: todoLastWeek)),
            notes: .init(total: noteTotal, trend: trend(thisWeek: noteThisWeek, lastWeek: noteLastWeek)),
            lists: .init(total: listTotal, trend: trend(thisWeek: listThisWeek, lastWeek: listLastWeek))
        )
    }

    private func trend(thisWeek: Int, lastWeek: Int) -> Int {
        if lastWeek == 0 { return thisWeek > 0 ? 100 : 0 }
        return Int((Double(thisWeek - lastWeek) / Double(lastWeek) * 100).rounded())
    }
}

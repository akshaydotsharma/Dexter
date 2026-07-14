import Foundation
import SwiftData

/// One-time backfill (#277): trip expenses became opt-in to Finance.
///
/// Every trip expense created before the opt-in checkbox was silently counted
/// in the Finance tab's totals. When the feature ships, flip all existing trip
/// expenses to hidden-from-Finance ONCE so the new default ("a trip expense is
/// not in Finance until you tick it") applies retroactively. New trip expenses
/// already default to hidden at their creation sites; this only touches rows
/// that predate the change.
///
/// - Idempotent: guarded by a `UserDefaults` flag, so it runs exactly once. If
///   the fetch throws we return WITHOUT setting the flag, so a transient
///   failure simply retries on the next launch.
/// - Safe: it only SETS the additive `hiddenFromFinance` flag. No deletes, and
///   it deliberately does NOT go through the #264 removal path (which can
///   hard-delete a row). A row hidden from Finance stays fully intact on its
///   trip and keeps feeding the trip's tiles / settle-up.
@MainActor
enum TripExpenseFinanceMigration {
    private static let flagKey = "didFlipTripExpensesOutOfFinance"

    static func runIfNeeded(context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flagKey) else { return }

        let descriptor = FetchDescriptor<LocalExpense>(
            predicate: #Predicate { $0.tripUUID != nil }
        )
        guard let tripExpenses = try? context.fetch(descriptor) else {
            // Fetch failed — leave the flag unset so we retry next launch.
            return
        }

        var changed = false
        for expense in tripExpenses where !expense.hiddenFromFinance {
            expense.hiddenFromFinance = true
            changed = true
        }
        if changed {
            try? context.save()
        }
        defaults.set(true, forKey: flagKey)
    }
}

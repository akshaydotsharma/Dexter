import SwiftUI

/// The window the Trends tab totals over (#545).
///
/// ### Why the default is seven days and not this month
///
/// Finance defaults to `thisMonth`, because a budget is a month. Eating is not.
/// A month-to-date window on the 2nd is two days of data wearing a month's
/// label, and by the 28th a change made last Tuesday is diluted by 27 days that
/// preceded it. Seven days is the shortest window where a steady pattern can be
/// told from one bad evening, and the longest where a change in behaviour is
/// still legible in the average. So the two sections disagree on purpose.
///
/// ### Every window ends today
///
/// `thisMonth` and `thisYear` are calendar periods whose calendar end is in the
/// future, and Finance lets them run to that end because an unspent future day
/// adds nothing to a total. Here it would: a day with no meals on it is an
/// UNLOGGED day, and counting 12 days you have not lived yet as days you failed
/// to log makes the logging-health strip lie. So the upper bound of every
/// preset is clamped to today.
enum MealTrendPeriod: String, CaseIterable, Identifiable, Hashable, Sendable {
    case last7
    case thisMonth
    case last30
    case last90
    case thisYear
    case custom

    var id: String { rawValue }

    /// The presets offered as chips, in the order they are offered. `custom`
    /// is not here: it is the trailing control, and it is selected by picking
    /// dates rather than by being tapped.
    static let presets: [MealTrendPeriod] = [.last7, .thisMonth, .last30, .last90, .thisYear]

    /// Chip label. Short, because five of them share a phone-width row.
    var displayName: String {
        switch self {
        case .last7:     return "7 days"
        case .thisMonth: return "This month"
        case .last30:    return "30 days"
        case .last90:    return "90 days"
        case .thisYear:  return "This year"
        case .custom:    return "Custom"
        }
    }

    /// Eyebrow above the collapsed band. Spelled out, because the band has the
    /// room the chip does not and the window is the first thing to establish.
    var bandLabel: String {
        switch self {
        case .last7:     return "Last 7 days"
        case .thisMonth: return "This month"
        case .last30:    return "Last 30 days"
        case .last90:    return "Last 90 days"
        case .thisYear:  return "This year"
        case .custom:    return "Custom range"
        }
    }

    /// How many whole days back a rolling preset reaches, INCLUDING today.
    ///
    /// Finance's `last30` subtracts 30 days from now, which gives a 31-day
    /// window. Here the count is the count: "30 days" is 30 day cells in the
    /// consistency strip, 30 in the chart, and a divisor that adds up against
    /// the logging-health strip beside it.
    var rollingDayCount: Int? {
        switch self {
        case .last7:  return 7
        case .last30: return 30
        case .last90: return 90
        case .thisMonth, .thisYear, .custom: return nil
        }
    }
}

/// The period the Trends tab is on, and the two dates a custom range needs.
///
/// `Hashable` so the tab can fold it into the `.task(id:)` signature that
/// decides whether the insights need recomputing (#442's lesson, applied here
/// before it can cost anything).
struct MealTrendSelection: Equatable, Hashable, Sendable {
    var period: MealTrendPeriod = .last7
    var customStart: Date = Date()
    var customEnd: Date = Date()

    /// The window as device-local day bounds: the first instant of the first
    /// day through the last instant of the last day.
    ///
    /// Device-local on purpose. A stored meal day is a UTC anchor (#506) and is
    /// compared as a day, never as an instant — `MealInsights` does that
    /// conversion at the boundary. Everything the user picks and everything a
    /// formatter prints is device-local.
    func resolvedRange(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: today)?
            .addingTimeInterval(-1) ?? now

        func window(dayCount: Int) -> ClosedRange<Date> {
            let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today
            return start...endOfToday
        }

        switch period {
        case .last7, .last30, .last90:
            return window(dayCount: period.rollingDayCount ?? 7)

        case .thisMonth:
            let comps = calendar.dateComponents([.year, .month], from: today)
            let start = calendar.date(from: comps) ?? today
            return start...endOfToday

        case .thisYear:
            let comps = calendar.dateComponents([.year], from: today)
            let start = calendar.date(from: comps) ?? today
            return start...endOfToday

        case .custom:
            let low = calendar.startOfDay(for: min(customStart, customEnd))
            let highDay = min(calendar.startOfDay(for: max(customStart, customEnd)), today)
            let high = calendar.date(byAdding: .day, value: 1, to: highDay)?
                .addingTimeInterval(-1) ?? endOfToday
            // A custom range whose whole span is in the future collapses onto
            // today rather than inverting.
            return low <= high ? low...high : today...endOfToday
        }
    }

    /// Band eyebrow. A custom range names its own dates, because "Custom range"
    /// on its own says nothing about what is being totalled.
    func bandLabel(calendar: Calendar = .current) -> String {
        guard period == .custom else { return period.bandLabel }
        let range = resolvedRange(calendar: calendar)
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return "\(formatter.string(from: range.lowerBound)) to \(formatter.string(from: range.upperBound))"
    }
}

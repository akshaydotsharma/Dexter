import SwiftUI

// MARK: - Week board

/// One row per day with its load bar (#687). An overloaded day turns red and
/// states the overflow; a tap opens that day's agenda.
struct PlannerWeekBoard: View {
    struct Row: Identifiable {
        let day: Date
        let summary: CapacitySummary
        let titles: [String]
        var id: Date { day }
    }

    let rows: [Row]
    let settings: WorkdaySettings
    let onOpen: (Date) -> Void

    private var compact: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Rectangle().fill(Tokens.divider).frame(height: 1) }
                Button { onOpen(row.day) } label: { rowView(row) }
                    .buttonStyle(.plain)
            }
        }
        .plannerCard()
    }

    private func hoursLabel(_ s: CapacitySummary) -> String {
        if s.isOver { return "\(PlannerFormat.duration(s.bookedMinutes)) · over \(PlannerFormat.duration(s.overflowMinutes))" }
        if s.isWorkday { return "\(PlannerFormat.duration(s.bookedMinutes)) of \(PlannerFormat.duration(s.capacityMinutes))" }
        return s.bookedMinutes == 0 ? "Free" : PlannerFormat.duration(s.bookedMinutes)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let isToday = Calendar.current.isDateInToday(row.day)
        let label = PlannerStyle.shortDayFormatter.string(from: row.day)
        Group {
            if compact {
                HStack(alignment: .center, spacing: 10) {
                    Text(label)
                        .font(.edFootnoteStrong)
                        .foregroundStyle(isToday ? Tokens.accentToday : Tokens.ink)
                        .frame(width: 58, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        PlannerMeterBar(summary: row.summary, scaleMinutes: settings.lengthMinutes, height: 8)
                        Text(hoursLabel(row.summary))
                            .font(.edCaption.weight(row.summary.isOver ? .semibold : .regular))
                            .foregroundStyle(row.summary.isOver ? Tokens.danger : Tokens.muted)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.mutedSoft)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            } else {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label)
                            .font(.edFootnoteStrong)
                            .foregroundStyle(isToday ? Tokens.accentToday : Tokens.ink)
                        Text(hoursLabel(row.summary))
                            .font(.edCaption.weight(row.summary.isOver ? .semibold : .regular))
                            .foregroundStyle(row.summary.isOver ? Tokens.danger : Tokens.muted)
                    }
                    .frame(width: 130, alignment: .leading)
                    PlannerMeterBar(summary: row.summary, scaleMinutes: settings.lengthMinutes)
                        .frame(width: 180)
                    Text(row.titles.isEmpty ? "Nothing planned" : summaryText(row.titles))
                        .font(.edCaption)
                        .foregroundStyle(row.titles.isEmpty ? Tokens.mutedSoft : Tokens.inkSoft)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if row.summary.isOver {
                        Text("Show fixes")
                            .font(.edCaption.weight(.semibold))
                            .foregroundStyle(Tokens.danger)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .overlay(Capsule().stroke(Tokens.danger, lineWidth: 1))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .background(isToday ? Tokens.accentToday.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(PlannerStyle.weekdayFormatter.string(from: row.day)), \(hoursLabel(row.summary))")
        .accessibilityHint("Opens the day")
    }

    private func summaryText(_ titles: [String]) -> String {
        if titles.count <= 4 { return titles.joined(separator: ", ") }
        return titles.prefix(3).joined(separator: ", ") + ", \(titles.count - 3) more"
    }
}


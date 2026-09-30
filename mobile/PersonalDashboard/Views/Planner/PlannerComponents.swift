import SwiftUI

// MARK: - Source grammar

/// Hue and shape per source (#687). Hues are existing tokens, so the Planner
/// adds no colour of its own: work is info cyan, personal is Activity plum, a
/// task is Tasks indigo, a manual block is ink with a hatch. Each also has a
/// SHAPE (solid tint, outline plus circle, hatch), so a row reads correctly
/// without colour.
enum PlannerStyle {
    static func color(_ source: PlannerSource) -> Color {
        switch source {
        case .work:     return Tokens.info
        case .personal: return Tokens.accentActivity
        case .task:     return Tokens.accentTasks
        case .manual:   return Tokens.inkSoft
        }
    }

    static func priorityColor(_ p: TaskPriority) -> Color {
        switch p {
        case .p0:          return Tokens.priorityRed
        case .p1:          return Tokens.priorityYellow
        case .p2, .none:   return Tokens.priorityGreen
        }
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm"
        return f
    }()

    static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        f.amSymbol = "AM"
        f.pmSymbol = "PM"
        return f
    }()

    /// "9:30" in the agenda's time column.
    static func clock(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// "3:30 PM", or "3 PM" on the hour.
    static func clockAP(_ date: Date) -> String {
        let s = shortTimeFormatter.string(from: date)
        return s.replacingOccurrences(of: ":00 ", with: " ")
    }

    /// "3:30 - 3:45 PM", or "11:30 AM - 1 PM" across noon.
    static func range(_ start: Date, _ end: Date, calendar: Calendar = .current) -> String {
        let sameHalf = (calendar.component(.hour, from: start) < 12) == (calendar.component(.hour, from: end) < 12)
        let s = clockAP(start)
        let lead = sameHalf ? s.replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "") : s
        return "\(lead) - \(clockAP(end))"
    }

    static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f
    }()
    static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMMM"; return f
    }()
    static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d"; return f
    }()
    static let weekdayShortFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
}

// MARK: - Hatch

/// Diagonal hatching, the manual block's shape.
struct PlannerHatch: View {
    var color: Color = Tokens.mutedSoft.opacity(0.45)
    var spacing: CGFloat = 7
    var lineWidth: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Day header

struct PlannerDayHeader: View {
    let day: Date
    var eyebrowOverride: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(eyebrowOverride ?? PlannerStyle.weekdayFormatter.string(from: day)).eyebrow()
            Text(PlannerStyle.dayMonthFormatter.string(from: day))
                .font(.edTitle)
                .foregroundStyle(Tokens.ink)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Source chips

struct PlannerSourceChips: View {
    let counts: [PlannerSource: Int]
    let hidden: Set<PlannerSource>
    let onToggle: (PlannerSource) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PlannerSource.allCases, id: \.self) { source in
                chip(source)
            }
        }
    }

    private func chip(_ source: PlannerSource) -> some View {
        let off = hidden.contains(source)
        let c = PlannerStyle.color(source)
        return Button { onToggle(source) } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(off ? Color.clear : c)
                    .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(c, lineWidth: off ? 1.5 : 0))
                    .frame(width: 8, height: 8)
                Text(source.label)
                    .font(.edCaption.weight(.medium))
                    .foregroundStyle(off ? Tokens.muted : Tokens.ink)
                if let n = counts[source], n > 0 {
                    Text("\(n)")
                        .font(.edMono)
                        .foregroundStyle(Tokens.muted)
                }
            }
            .padding(.leading, 7).padding(.trailing, 9).padding(.vertical, 4)
            .background(off ? Color.clear : Tokens.surface, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Tokens.border, style: StrokeStyle(lineWidth: 1, dash: off ? [3, 2] : []))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(source.label), \(off ? "hidden" : "shown")")
        .accessibilityHint("Shows or hides \(source.label.lowercased())")
    }
}

// MARK: - Meter

/// A bar of booked time by source, with any overflow hatched in danger.
struct PlannerMeterBar: View {
    let summary: CapacitySummary
    /// Minutes the full width stands for.
    let scaleMinutes: Int
    var height: CGFloat = 10

    static let order: [PlannerSource] = [.work, .personal, .manual, .task]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let scale = CGFloat(max(1, max(scaleMinutes, summary.bookedMinutes)))
            let limit = summary.isOver ? summary.capacityMinutes : Int.max
            HStack(spacing: 0) {
                ForEach(segments(limit: limit), id: \.0) { source, mins in
                    segment(source).frame(width: w * CGFloat(mins) / scale)
                }
                if summary.isOver {
                    ZStack {
                        Tokens.danger.opacity(0.45)
                        PlannerHatch(color: Tokens.danger, spacing: 6, lineWidth: 2.2)
                    }
                    .frame(width: w * CGFloat(summary.overflowMinutes) / scale)
                    .clipped()
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Tokens.paper2)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Tokens.border, lineWidth: 1))
        .accessibilityHidden(true)
    }

    /// Source segments in bar order, cut off at `limit` cumulative minutes.
    private func segments(limit: Int) -> [(PlannerSource, Int)] {
        var left = limit
        var out: [(PlannerSource, Int)] = []
        for s in Self.order {
            let m = min(summary.minutes(s), left)
            if m > 0 { out.append((s, m)); left -= m }
            if left <= 0 { break }
        }
        return out
    }

    @ViewBuilder
    private func segment(_ source: PlannerSource) -> some View {
        // Solid, like every tile: one fill treatment for every source.
        PlannerStyle.color(source)
    }
}

/// The capacity card: "6h booked of 9h workday", the bar and the per-source keys.
struct PlannerMeterCard: View {
    let summary: CapacitySummary
    let settings: WorkdaySettings
    /// Opens the "Can move" list on an overloaded day.
    var onFixes: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(PlannerFormat.duration(summary.bookedMinutes)) booked")
                        .font(.edTitle)
                        .foregroundStyle(summary.isOver ? Tokens.danger : Tokens.ink)
                        .lineLimit(1)
                    Text(summary.isWorkday ? "of \(PlannerFormat.duration(settings.lengthMinutes))" : "not a workday")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: Space.sm)
                if summary.isOver {
                    Text("over \(PlannerFormat.duration(summary.overflowMinutes))")
                        .font(.edFootnoteStrong)
                        .foregroundStyle(Tokens.danger)
                } else if summary.isWorkday {
                    Text("\(PlannerFormat.duration(summary.freeMinutes)) free")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                }
            }
            PlannerMeterBar(summary: summary, scaleMinutes: settings.lengthMinutes)
            PlannerFlow(spacing: 10) {
                ForEach(PlannerMeterBar.order, id: \.self) { s in
                    let m = summary.minutes(s)
                    if m > 0 {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(PlannerStyle.color(s)).frame(width: 7, height: 7)
                            Text("\(s.meterLabel) \(PlannerFormat.duration(m))")
                                .font(.edCaption)
                                .foregroundStyle(Tokens.muted)
                        }
                    }
                }
                if summary.bookedMinutes == 0 {
                    Text("Nothing booked yet")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                }
                if summary.isOver, let onFixes {
                    Button("Show fixes", action: onFixes)
                        .buttonStyle(PlannerSmallButtonStyle(danger: true))
                }
            }
        }
        .padding(Space.md + 2)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .paperBorder()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var s = "\(PlannerFormat.duration(summary.bookedMinutes)) booked"
        if summary.isWorkday { s += " of \(PlannerFormat.duration(settings.lengthMinutes))" }
        if summary.isOver { s += ", over by \(PlannerFormat.duration(summary.overflowMinutes))" }
        else if summary.isWorkday { s += ", \(PlannerFormat.duration(summary.freeMinutes)) free" }
        return s
    }
}

// MARK: - All-day row

struct PlannerAllDayRow: View {
    let items: [PlannerItem]
    let onTap: (PlannerItem) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("All\nday")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Tokens.muted)
                .multilineTextAlignment(.trailing)
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 2)
            PlannerFlow(spacing: 4) {
                ForEach(items) { item in
                    Button { onTap(item) } label: { pill(item) }
                        .buttonStyle(.plain)
                }
            }
            // Take the offered width, so the flow measures its wrapped height
            // against the width it is placed in, not an unbounded one.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.trailing, Space.sm)
    }

    /// The same tile as the grid (#687 round 2): stripe plus a light tint of
    /// the source colour. Overdue is state, so it is a danger ring and a red note.
    private func pill(_ item: PlannerItem) -> some View {
        let c = PlannerStyle.color(item.source)
        return HStack(spacing: 5) {
            Rectangle().fill(c).frame(width: 3)
            if item.source == .task {
                Image(systemName: "circle")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(c)
            }
            Text(item.title)
                .font(.edCaption.weight(.medium))
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
            if let note = note(item) {
                Text(note)
                    .font(.system(size: 9.5, weight: item.overdueDays > 0 ? .semibold : .regular))
                    .foregroundStyle(item.overdueDays > 0 ? Tokens.danger : Tokens.muted)
                    .lineLimit(1)
            }
        }
        .padding(.trailing, 7)
        .frame(height: 22)
        .background(ZStack { Tokens.surface; c.opacity(0.16) })
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            if item.overdueDays > 0 {
                RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Tokens.danger, lineWidth: 1.2)
            }
        }
        .accessibilityLabel([item.title, note(item)].compactMap { $0 }.joined(separator: ", "))
    }

    private func note(_ item: PlannerItem) -> String? {
        if item.overdueDays > 0 { return item.overdueDays == 1 ? "1 day overdue" : "\(item.overdueDays) days overdue" }
        if item.isBlock { return "no time · \(PlannerFormat.duration(item.durationMinutes))" }
        if case .taskDue = item.origin { return "due today" }
        return nil
    }
}

// MARK: - Buttons

struct PlannerSmallButtonStyle: ButtonStyle {
    var filled: Bool = false
    var tint: Color = Tokens.accentTasks
    var danger: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.edCaption.weight(.semibold))
            .foregroundStyle(filled ? Tokens.surface : (danger ? Tokens.danger : Tokens.ink))
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(filled ? tint : Tokens.surface, in: Capsule())
            .overlay(Capsule().stroke(filled ? tint : (danger ? Tokens.danger : Tokens.borderStrong), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - Flow layout

/// Left-to-right wrapping layout for chips.
struct PlannerFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
            if x > 0, x + s.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + s.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(s.width, bounds.width), height: s.height))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Card

extension View {
    func plannerCard(padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .paperBorder()
    }
}

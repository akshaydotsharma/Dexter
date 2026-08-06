import SwiftUI

/// What the calendar is doing to a block (#446).
///
/// Derived from the soonest due date among the block's INCOMPLETE tiles, never
/// typed by the user, so it cannot go stale. It is the second of the two things
/// a block says at once: `BlockState` is what you are doing about the work,
/// this is what the deadline is doing to you.
///
/// The two never compete for a pixel. State owns the block's top edge and the
/// leading glyph; urgency owns the header's trailing edge, in a different shape
/// language (a capsule with words, against a bar and a glyph).
enum VisionUrgency: Equatable {
    /// Rung 0. No incomplete tile has a due date. The chip is absent entirely.
    case none
    /// Rung 1. More than a week out.
    case distant(days: Int)
    /// Rung 2. Two to seven days.
    case soon(days: Int)
    /// Rung 3.
    case tomorrow
    /// Rung 4.
    case today
    /// Rung 5.
    case overdue(days: Int)

    /// Position on the escalation ladder, 0 to 5.
    ///
    /// Rungs 0 to 3 are entirely hueless, and that is the whole design. On a
    /// board of twenty blocks most are weeks out; if every one of them carried a
    /// coloured chip the board would be a wall of pastel and the two blocks that
    /// actually need you would be invisible. Warmth arrives at rung 4 and 5,
    /// where warmth is correct.
    var rung: Int {
        switch self {
        case .none:     return 0
        case .distant:  return 1
        case .soon:     return 2
        case .tomorrow: return 3
        case .today:    return 4
        case .overdue:  return 5
        }
    }

    var text: String {
        switch self {
        case .none:                return ""
        case .distant(let days):   return Self.phrase(forDaysAhead: days)
        case .soon(let days):      return "in \(days) days"
        case .tomorrow:            return "tomorrow"
        case .today:               return "today"
        case .overdue(let days):   return "overdue by \(days)"
        }
    }

    /// Spoken form for the block's accessibility label. `none` says nothing
    /// rather than "no urgency", which would be a sentence about an absence.
    var accessibilityPhrase: String {
        switch self {
        case .none:              return ""
        case .overdue(let days): return "Overdue by \(days) \(days == 1 ? "day" : "days")"
        default:                 return "Due \(text)"
        }
    }

    /// Derive from a block's tiles. Completed tiles are ignored: a finished task
    /// cannot make a block urgent, and counting it would leave a block reading
    /// `overdue by 3` for work that is done.
    static func derive(from tiles: [Todo], now: Date = Date()) -> VisionUrgency {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        // Whole calendar days, not elapsed hours. "Tomorrow" has to mean the
        // next date on the wall calendar; an hours-based comparison makes a task
        // due at 09:00 tomorrow read as "today" when it is 22:00 tonight.
        let deltas = tiles
            .filter { !$0.completed }
            .compactMap { $0.dueDate }
            .compactMap { calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: $0)).day }

        guard let soonest = deltas.min() else { return .none }

        if soonest < 0  { return .overdue(days: -soonest) }
        if soonest == 0 { return .today }
        if soonest == 1 { return .tomorrow }
        if soonest <= 7 { return .soon(days: soonest) }
        return .distant(days: soonest)
    }

    /// Coarsens as it gets further away, because precision stops being worth
    /// anything past a fortnight: "in 3 weeks" is what you would say, and "in 23
    /// days" is a number nobody converts.
    private static func phrase(forDaysAhead days: Int) -> String {
        if days < 14 { return "in \(days) days" }
        if days < 60 {
            let weeks = Int((Double(days) / 7).rounded())
            return "in \(weeks) weeks"
        }
        let months = Int((Double(days) / 30.44).rounded())
        return months <= 1 ? "in a month" : "in \(months) months"
    }
}

// MARK: - The chip

/// The urgency capsule at a block header's trailing edge.
///
/// Five axes escalate together — text colour, container, icon, type size, and
/// the literal words — so no single perceptual channel carries the ladder.
/// Rungs 3, 4 and 5 are told apart in pure greyscale by icon shape alone:
/// nothing, a circle, a triangle.
struct VisionUrgencyChip: View {
    let urgency: VisionUrgency
    let tier: VisionBlockTier

    var body: some View {
        if !isSuppressed {
            content
        }
    }

    /// Rungs 1 and 2 are dropped at small. There is 172pt of width and the title
    /// needs it; "in 3 weeks" is not worth a truncated title. Rungs 3 to 5 show
    /// at every size, because those are the ones you scan for.
    private var isSuppressed: Bool {
        urgency.rung == 0 || (tier == .small && urgency.rung <= 2)
    }

    @ViewBuilder
    private var content: some View {
        switch urgency {
        case .none:
            EmptyView()

        case .distant:
            // No container, no padding, only text. Most of the board lives here.
            Text(urgency.text)
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .lineLimit(1)

        case .soon:
            Text(urgency.text)
                .font(.edCaption)
                .foregroundStyle(Tokens.inkSoft)
                .lineLimit(1)

        case .tomorrow:
            capsule(icon: nil, iconTint: nil, fill: Tokens.surface2, stroke: Tokens.border)

        case .today:
            capsule(icon: "clock", iconTint: Tokens.warning, fill: Tokens.warningSoft, stroke: Tokens.warning)

        case .overdue:
            capsule(
                icon: "exclamationmark.triangle.fill",
                iconTint: Tokens.danger,
                fill: Tokens.dangerSoft,
                stroke: Tokens.danger
            )
        }
    }

    /// Metrics identical to `TagPill`, so a board chip and a tag pill are the
    /// same physical object at different sizes.
    ///
    /// The TEXT stays `Tokens.ink` at every rung and the hue is carried by the
    /// fill, the hairline and the icon. That is a contrast decision, not a style
    /// one: `Tokens.warning` on `Tokens.warningSoft` measures 4.51:1, the
    /// tightest pair in the app and passing by 0.01. As an icon and a hairline
    /// it clears the 3:1 graphic floor comfortably; as text it would be sitting
    /// on the line. `Tokens.ink` on `warningSoft` is 15.4:1, and the chip still
    /// reads unmistakably amber because three of its four elements are amber.
    private func capsule(icon: String?, iconTint: Color?, fill: Color, stroke: Color) -> some View {
        HStack(spacing: Space.xs) {
            if let icon, let iconTint {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(iconTint)
            }
            Text(urgency.text)
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 2)
        .background(fill, in: Capsule())
        .overlay(Capsule().stroke(stroke, lineWidth: 0.5))
    }
}

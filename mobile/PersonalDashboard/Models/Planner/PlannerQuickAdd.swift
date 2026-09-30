import Foundation

/// Reads one line of text into a manual block, on the device, with no AI call
/// (#687). "Call bank 3:30pm 15m" is a 15 minute block at 3:30 PM titled "Call
/// bank".
///
/// What it understands, anywhere in the line:
///
/// - A time: `3pm`, `3:30pm`, `3:30 pm`, `15:30`, `at 9`, `noon`. A bare hour
///   with no am/pm and no colon only counts after "at". Without am/pm, 1 to 6
///   reads as the afternoon and 7 to 11 as the morning, since a planner is
///   read in working hours.
/// - A range: `9-10am`, `2pm-3:30pm`, `14:00-15:00`, `2 to 3pm`.
/// - A length: `15m`, `45 min`, `1h`, `1.5h`, `1h30`, `1h 30m`, `90 mins`.
/// - A day: `today`, `tomorrow`, `tmrw`, or a weekday (`fri`, `friday`), which
///   means the next such day, or the given day itself when it matches.
///
/// No time means the block is planned to the day with no hour. No length means
/// 30 minutes. Whatever text is left is the title.
enum PlannerQuickAdd {

    struct Result: Equatable {
        var title: String
        /// Device-local midnight of the day.
        var day: Date
        var start: Date?
        var durationMinutes: Int

        var end: Date? { start.map { $0.addingTimeInterval(TimeInterval(durationMinutes * 60)) } }
        var isTimed: Bool { start != nil }
    }

    static let defaultDuration = 30

    static func parse(_ raw: String, on baseDay: Date, calendar: Calendar = .current) -> Result {
        var text = " " + raw + " "
        var day = calendar.startOfDay(for: baseDay)
        var startMinute: Int?
        var duration: Int?

        // 1. Day words.
        if let m = firstMatch(#"(?i)\b(today|tonight)\b"#, in: text) {
            text = blank(m.range, in: text)
        } else if let m = firstMatch(#"(?i)\b(tomorrow|tmrw|tmr)\b"#, in: text) {
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            text = blank(m.range, in: text)
        } else if let m = firstMatch(#"(?i)\b(?:on\s+)?(mon|monday|tue|tues|tuesday|wed|weds|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday|sun|sunday)\b"#, in: text),
                  let target = weekday(from: group(1, m, in: text)) {
            let current = calendar.component(.weekday, from: day)
            let offset = (target - current + 7) % 7
            day = calendar.date(byAdding: .day, value: offset, to: day) ?? day
            text = blank(m.range, in: text)
        }

        // 2. A range. Must run before the single time so "9-10am" is one match.
        let rangePattern = #"(?i)(?:\bfrom\s+)?\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:-|–|to)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#
        if let m = firstMatch(rangePattern, in: text) {
            let h1 = Int(group(1, m, in: text)) ?? 0
            let m1 = Int(group(2, m, in: text)) ?? 0
            let ap1 = group(3, m, in: text).lowercased()
            let h2 = Int(group(4, m, in: text)) ?? 0
            let m2 = Int(group(5, m, in: text)) ?? 0
            let ap2 = group(6, m, in: text).lowercased()
            // A range needs SOME sign it is a time: a meridiem or a colon.
            let looksLikeTime = !ap1.isEmpty || !ap2.isEmpty
                || !group(2, m, in: text).isEmpty || !group(5, m, in: text).isEmpty
            if looksLikeTime, h1 <= 23, h2 <= 23, m1 < 60, m2 < 60 {
                // "9-10am": the first hour borrows the second's meridiem when it
                // has none, unless that would put it after the end ("11-1pm").
                let endMin = minuteOfDay(hour: h2, minute: m2, meridiem: ap2)
                var startMin = minuteOfDay(hour: h1, minute: m1, meridiem: ap1.isEmpty ? ap2 : ap1)
                if ap1.isEmpty, !ap2.isEmpty, startMin > endMin {
                    startMin = minuteOfDay(hour: h1, minute: m1, meridiem: ap2 == "pm" ? "am" : "pm")
                }
                if endMin > startMin {
                    startMinute = startMin
                    duration = endMin - startMin
                    text = blank(m.range, in: text)
                }
            }
        }

        // 3. A length.
        if duration == nil {
            let hm = #"(?i)\b(?:for\s+)?(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)(?:\s*(\d{1,2})(?![:\d])(?:\s*(?:m|min|mins|minutes))?\b(?!\s*(?:am|pm)))?\b"#
            let mOnly = #"(?i)\b(?:for\s+)?(\d{1,3})\s*(?:m|min|mins|minute|minutes)\b"#
            if let m = firstMatch(hm, in: text) {
                let hours = Double(group(1, m, in: text)) ?? 0
                let extra = Int(group(2, m, in: text)) ?? 0
                let total = Int((hours * 60).rounded()) + extra
                if total > 0 { duration = total; text = blank(m.range, in: text) }
            } else if let m = firstMatch(mOnly, in: text) {
                let total = Int(group(1, m, in: text)) ?? 0
                if total > 0 { duration = total; text = blank(m.range, in: text) }
            }
        }

        // 4. A single time.
        if startMinute == nil {
            if let m = firstMatch(#"(?i)\b(?:at\s+)?(noon|midday)\b"#, in: text) {
                startMinute = 12 * 60
                text = blank(m.range, in: text)
            } else if let m = firstMatch(#"(?i)\b(?:at\s+)?(\d{1,2}):(\d{2})\s*(am|pm)?\b"#, in: text) {
                let h = Int(group(1, m, in: text)) ?? 0
                let mm = Int(group(2, m, in: text)) ?? 0
                if h <= 23, mm < 60 {
                    startMinute = minuteOfDay(hour: h, minute: mm, meridiem: group(3, m, in: text).lowercased())
                    text = blank(m.range, in: text)
                }
            } else if let m = firstMatch(#"(?i)\b(?:at\s+)?(\d{1,2})\s*(am|pm)\b"#, in: text) {
                let h = Int(group(1, m, in: text)) ?? 0
                if (1...12).contains(h) {
                    startMinute = minuteOfDay(hour: h, minute: 0, meridiem: group(2, m, in: text).lowercased())
                    text = blank(m.range, in: text)
                }
            } else if let m = firstMatch(#"(?i)\bat\s+(\d{1,2})\b"#, in: text) {
                let h = Int(group(1, m, in: text)) ?? 0
                if h <= 23 {
                    startMinute = minuteOfDay(hour: h, minute: 0, meridiem: "")
                    text = blank(m.range, in: text)
                }
            }
        }

        // 5. What is left is the title.
        var title = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Connectives the parse stranded at an edge ("Call bank at", "for").
        for word in ["at", "for", "on", "from", "by", "-", ",", "·"] {
            while title.lowercased().hasSuffix(" " + word) || title.lowercased() == word {
                title = String(title.dropLast(word.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if title.isEmpty { title = "Block" }

        let start = startMinute.map { day.addingTimeInterval(TimeInterval($0 * 60)) }
        return Result(
            title: title,
            day: day,
            start: start,
            durationMinutes: min(max(duration ?? defaultDuration, 5), 24 * 60)
        )
    }

    // MARK: - Pieces

    /// Minutes after midnight. With no meridiem, 1-6 is read as pm and 12 as
    /// noon; 0 and 13-23 are already 24-hour.
    static func minuteOfDay(hour: Int, minute: Int, meridiem: String) -> Int {
        var h = hour
        switch meridiem {
        case "am": if h == 12 { h = 0 }
        case "pm": if h < 12 { h += 12 }
        default:   if (1...6).contains(h) { h += 12 }
        }
        return min(h, 23) * 60 + minute
    }

    private static func weekday(from word: String) -> Int? {
        switch String(word.lowercased().prefix(3)) {
        case "sun": return 1
        case "mon": return 2
        case "tue": return 3
        case "wed": return 4
        case "thu": return 5
        case "fri": return 6
        case "sat": return 7
        default:    return nil
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ i: Int, _ m: NSTextCheckingResult, in text: String) -> String {
        guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: text) else { return "" }
        return String(text[r])
    }

    private static func blank(_ range: NSRange, in text: String) -> String {
        guard let r = Range(range, in: text) else { return text }
        return text.replacingCharacters(in: r, with: " ")
    }
}

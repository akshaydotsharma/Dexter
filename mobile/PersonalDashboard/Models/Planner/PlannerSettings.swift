import Foundation

/// The Planner's few settings (#687), in `UserDefaults`.
///
/// Per device on purpose. EventKit calendar identifiers are local to one
/// device, so a Work/Personal tag keyed on one would mean nothing on the other.
/// The workday is per device for the same reason the theme is: it is how this
/// screen reads, not a fact about the data.
enum PlannerSettings {
    enum Key {
        static let workdayStartMinute = "planner.workdayStartMinute"
        static let workdayLengthMinutes = "planner.workdayLengthMinutes"
        /// JSON `[calendarIdentifier: "work" | "personal"]`, only the overrides.
        static let calendarTags = "planner.calendarTags"
        /// JSON `[calendarIdentifier]` the user turned off.
        static let hiddenCalendars = "planner.hiddenCalendars"
        /// Comma list of `PlannerSource` raw values the chips hid.
        static let hiddenSources = "planner.hiddenSources"
    }

    static let defaultStartMinute = 9 * 60
    static let defaultLengthMinutes = 9 * 60

    static var defaults: UserDefaults { .standard }

    static var workday: WorkdaySettings {
        let start = defaults.object(forKey: Key.workdayStartMinute) as? Int ?? defaultStartMinute
        let length = defaults.object(forKey: Key.workdayLengthMinutes) as? Int ?? defaultLengthMinutes
        return WorkdaySettings(
            startMinute: min(max(start, 0), 23 * 60),
            lengthMinutes: min(max(length, 60), 16 * 60)
        )
    }

    static var calendarTags: [String: PlannerSource] {
        get {
            guard let data = defaults.data(forKey: Key.calendarTags),
                  let raw = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return raw.compactMapValues(PlannerSource.init(rawValue:))
        }
        set {
            let raw = newValue.mapValues(\.rawValue)
            defaults.set(try? JSONEncoder().encode(raw), forKey: Key.calendarTags)
        }
    }

    static var hiddenCalendars: Set<String> {
        get {
            guard let data = defaults.data(forKey: Key.hiddenCalendars),
                  let raw = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(raw)
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue.sorted()), forKey: Key.hiddenCalendars)
        }
    }

    static func decodeSources(_ raw: String) -> Set<PlannerSource> {
        Set(raw.split(separator: ",").compactMap { PlannerSource(rawValue: String($0)) })
    }

    static func encodeSources(_ set: Set<PlannerSource>) -> String {
        set.map(\.rawValue).sorted().joined(separator: ",")
    }
}

/// The default Work/Personal tag for a calendar (#687), before the user changes
/// it in Settings.
///
/// A calendar is Work when its account looks like an employer's: an Exchange
/// account, an email address on a domain that is not a consumer mail provider,
/// or the word "work" in its title. Everything else is Personal. The user can
/// flip any calendar, so this only has to be a good first guess.
enum PlannerCalendarTagging {
    static let consumerDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com",
        "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com",
        "ymail.com", "proton.me", "protonmail.com", "aol.com", "gmx.com",
        "hey.com", "fastmail.com", "zoho.com", "yandex.com",
    ]

    static func defaultTag(sourceTitle: String, calendarTitle: String, isExchange: Bool) -> PlannerSource {
        if isExchange { return .work }
        for text in [sourceTitle, calendarTitle] {
            if let domain = emailDomain(in: text) {
                return consumerDomains.contains(domain) ? .personal : .work
            }
        }
        let lower = (sourceTitle + " " + calendarTitle).lowercased()
        if lower.range(of: #"\bwork\b"#, options: .regularExpression) != nil { return .work }
        return .personal
    }

    static func emailDomain(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let tail = text[text.index(after: at)...]
        let domain = tail.prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        let cleaned = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.contains(".") ? cleaned : nil
    }
}

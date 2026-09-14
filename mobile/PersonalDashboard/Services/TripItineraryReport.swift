import Foundation

/// The trip itinerary report, as data (#532).
///
/// Everything the exported PDF says lives here, already worded and already
/// formatted. There is no SwiftUI in this file and nothing on it needs the main
/// actor, so the whole document can be asserted in a test without rendering a
/// single view.
///
/// Two rules shape the build, the same two the expense report follows (#528):
///
/// 1. **The document comes from what the screen already computed.** The days,
///    their order, the stay that splits into a check-in and a check-out entry,
///    and the time each entry prints all arrive as the timeline's own
///    `TimelineEntry` grouping. The report never re-groups, so it cannot
///    disagree with the tab it was exported from.
/// 2. **A day inside the trip is never missing.** A day with nothing on it
///    prints and says it is free. An itinerary that silently skips 11 June
///    reads as a lost booking.
struct TripItineraryReport {

    // MARK: - Sections

    struct Cover {
        let tripName: String
        let dateRange: String
        /// Days in the trip's own range, inclusive.
        let dayCount: Int
        /// Entries on the timeline. A stay spanning days counts its check-in
        /// and its check-out separately, exactly as the timeline shows them.
        let stopCount: Int
        /// "3 stays", "2 flights", … in the order the trip is made of.
        let kindCounts: [KindCount]
        let scopeSentence: String
        let timeSentence: String
        /// What this export left out, when a toggle was turned off. Nil when
        /// the document carries everything.
        let omissionSentence: String?
        let exportedOn: String
    }

    struct KindCount: Identifiable {
        let id: String
        let label: String
        let count: Int
        let icon: String
    }

    /// One entry on the timeline, as a printed row.
    struct StopRow: Identifiable {
        let id: String
        /// "Anytime" / "10:35" / "10:35 → 15:35" / "Check-out · 11:00". The
        /// timeline's own wording, so the paper reads like the screen.
        let time: String
        let title: String
        /// "Flight" / "Stay" / "Restaurant" — the mode for a transport item,
        /// the kind otherwise.
        let kind: String
        let icon: String
        /// Where it is, what it is booked under, and the notes. Each line is
        /// already short enough to print on one line: the wrapping is done
        /// here, so the page height is known before anything is rendered.
        let details: [String]
        /// Carries a pass or a booking reference.
        let isBooked: Bool
    }

    struct Day: Identifiable {
        let id: String
        /// "Day 2 · Wed, 3 Jun 2026", or the date alone for a stop that sits
        /// outside the trip's own range.
        let title: String
        /// "3 stops", or "Nothing planned" on a free day.
        let subtitle: String
        let rows: [StopRow]
    }

    struct StayRow: Identifiable {
        let id: String
        let name: String
        /// "3 Jun → 6 Jun".
        let dates: String
        /// "3 nights", or "1 night". Empty when the stay has no check-out day.
        let nights: String
        /// Address and booking reference, joined.
        let detail: String
    }

    struct TravelRow: Identifiable {
        let id: String
        /// "3 Jun".
        let date: String
        /// "Flight" / "Train" / "Ferry".
        let mode: String
        /// "SIN → FCO" when the ticket carries both codes, the stop's title
        /// otherwise.
        let route: String
        /// "10:35 → 15:35", or the departure alone.
        let times: String
        /// Flight number, seat, gate, reference — whatever the stop holds.
        let detail: String
    }

    // MARK: - The report

    let cover: Cover
    let days: [Day]
    let stays: [StayRow]
    let travel: [TravelRow]
    /// "Italy itinerary 2026-09-14.pdf".
    let fileName: String
}

// MARK: - Input

/// Everything the report needs from the Itinerary tab.
///
/// `days` is the timeline's own grouping, handed over rather than rebuilt. That
/// is the whole reason the printed plan and the scrolled plan cannot drift: the
/// day buckets, the UTC-anchored day keys, the untimed-first sort and the
/// stay's two entries are all decided once, in `TripDetailView.grouped`.
struct TripItineraryReportInput {
    let tripName: String
    /// The trip's own anchored day range, used for "Day N of M" and for the
    /// free days the timeline has no bucket for.
    let startDate: Date
    let endDate: Date

    /// Day-ascending, entries in render order.
    let days: [(day: Date, entries: [TimelineEntry])]

    /// Personal notes are off by default when they are off: an itinerary sent
    /// to the group should not carry "ask Priya about the money" unless the
    /// person exporting it said so.
    let includeNotes: Bool
    /// Booking references, seats and gates.
    let includeReferences: Bool

    let exportDate: Date
}

// MARK: - Build

extension TripItineraryReport {

    static func make(_ input: TripItineraryReportInput) -> TripItineraryReport {
        let tripStart = WallClock.startOfStoredDay(input.startDate)
        let tripEnd = WallClock.startOfStoredDay(input.endDate)

        let days = buildDays(input: input, tripStart: tripStart, tripEnd: tripEnd)
        let items = uniqueItems(in: input.days)

        let stopCount = input.days.reduce(0) { $0 + $1.entries.count }
        let dayCount = max(WallClock.storedDayCount(from: tripStart, to: tripEnd) + 1, 1)

        let cover = Cover(
            tripName: input.tripName,
            dateRange: Self.dateRange(input.startDate, input.endDate),
            dayCount: dayCount,
            stopCount: stopCount,
            kindCounts: buildKindCounts(items),
            scopeSentence: Self.scopeSentence(days: dayCount, stops: stopCount),
            timeSentence: Self.timeSentence,
            omissionSentence: Self.omissionSentence(
                notes: input.includeNotes,
                references: input.includeReferences
            ),
            exportedOn: TripExpenseReport.longDate(input.exportDate)
        )

        return TripItineraryReport(
            cover: cover,
            days: days,
            stays: buildStays(items, includeReferences: input.includeReferences),
            travel: buildTravel(items, includeReferences: input.includeReferences),
            fileName: Self.fileName(tripName: input.tripName, on: input.exportDate)
        )
    }

    /// Every stop behind the timeline, once each and in timeline order. A stay
    /// shows up twice on the timeline and must be summarised once.
    private static func uniqueItems(
        in days: [(day: Date, entries: [TimelineEntry])]
    ) -> [LocalItineraryItem] {
        var seen: Set<UUID> = []
        var items: [LocalItineraryItem] = []
        for day in days {
            for entry in day.entries where seen.insert(entry.item.clientUUID).inserted {
                items.append(entry.item)
            }
        }
        return items
    }

    // MARK: - Day by day

    private static func buildDays(
        input: TripItineraryReportInput,
        tripStart: Date,
        tripEnd: Date
    ) -> [Day] {
        var buckets: [Date: [TimelineEntry]] = [:]
        for day in input.days { buckets[day.day] = day.entries }

        // Every day of the trip, plus any day a stop landed on outside it (an
        // early flight out, a late return). A free day inside the trip prints
        // as free; a day outside the trip with nothing on it does not print at
        // all, or a one-week trip booked a year ahead would run to 365 pages.
        var keys = Set(buckets.keys)
        if tripEnd >= tripStart {
            var cursor = tripStart
            while cursor <= tripEnd {
                keys.insert(cursor)
                cursor = WallClock.storedDay(cursor, byAdding: 1)
            }
        }

        return keys.sorted().map { day in
            let entries = buckets[day] ?? []
            let withinTrip = day >= tripStart && day <= tripEnd
            let number = WallClock.storedDayCount(from: tripStart, to: day) + 1
            let date = WallClock.deviceDay(from: day)
                .formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())

            return Day(
                id: ISO8601DateFormatter().string(from: day),
                title: withinTrip ? "Day \(number) · \(date)" : date,
                subtitle: entries.isEmpty ? "Nothing planned" : stopWord(entries.count),
                rows: entries.map { stopRow($0, input: input) }
            )
        }
    }

    private static func stopRow(
        _ entry: TimelineEntry,
        input: TripItineraryReportInput
    ) -> StopRow {
        let item = entry.item
        var details: [String] = []

        let place = [item.venue, item.address]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != item.title }
        if !place.isEmpty {
            details.append(contentsOf: wrap(place.joined(separator: " · "), lines: 2))
        }

        if input.includeReferences {
            let booking = bookingLine(item, avoiding: item.title)
            if !booking.isEmpty { details.append(contentsOf: wrap(booking, lines: 2)) }
        }

        if input.includeNotes {
            let notes = item.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty { details.append(contentsOf: wrap(notes, lines: 3)) }
        }

        return StopRow(
            id: entry.id,
            time: entry.dateTimeLine,
            title: item.title,
            kind: kindLabel(item),
            icon: kindIcon(item),
            details: details,
            isBooked: item.hasTicket || !item.sourceConfirmation.isEmpty
        )
    }

    /// The booking facts a person standing at a counter needs: what it is
    /// booked under, where they sit, which gate. Nothing here is money.
    ///
    /// `avoiding` is the text already printed above this line. An imported
    /// flight is titled after its own flight number ("TR 280 · SIN→DPS"), so
    /// without this the row reads "TR 280 · SIN→DPS / Scoot · TR 280 · …" and
    /// the reader checks twice whether those are two different flights.
    private static func bookingLine(_ item: LocalItineraryItem, avoiding printed: String = "") -> String {
        let meta = item.ticketMeta
        var parts: [String] = []

        // Compared without spaces, because a title says "TR280" as often as
        // the ticket says "TR 280".
        let alreadyPrinted = printed.replacingOccurrences(of: " ", with: "").lowercased()
        func isEchoed(_ value: String) -> Bool {
            guard !alreadyPrinted.isEmpty else { return false }
            let needle = value.replacingOccurrences(of: " ", with: "").lowercased()
            return !needle.isEmpty && alreadyPrinted.contains(needle)
        }

        if let airline = meta?.airline?.trimmed, !airline.isEmpty, !isEchoed(airline) { parts.append(airline) }
        if let number = meta?.flightNumber?.trimmed, !number.isEmpty, !isEchoed(number) { parts.append(number) }
        if !item.seat.isEmpty { parts.append("Seat \(item.seat)") }
        if !item.gate.isEmpty { parts.append("Gate \(item.gate)") }
        if let terminal = meta?.terminal?.trimmed, !terminal.isEmpty { parts.append("Terminal \(terminal)") }
        let reference = item.sourceConfirmation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reference.isEmpty { parts.append("Ref \(reference)") }

        return parts.joined(separator: " · ")
    }

    // MARK: - Stays

    private static func buildStays(
        _ items: [LocalItineraryItem],
        includeReferences: Bool
    ) -> [StayRow] {
        items
            .filter { $0.kindEnum == .stay }
            .sorted { WallClock.startOfStoredDay($0.dayDate) < WallClock.startOfStoredDay($1.dayDate) }
            .map { item in
                let checkIn = WallClock.startOfStoredDay(item.dayDate)
                let checkOut = item.endDate.map { WallClock.startOfStoredDay($0) }

                let dates: String
                let nights: String
                if let checkOut, checkOut > checkIn {
                    let count = WallClock.storedDayCount(from: checkIn, to: checkOut)
                    dates = "\(shortDay(checkIn)) → \(shortDay(checkOut))"
                    nights = count == 1 ? "1 night" : "\(count) nights"
                } else {
                    dates = shortDay(checkIn)
                    nights = ""
                }

                var detail: [String] = []
                let address = item.address.trimmingCharacters(in: .whitespacesAndNewlines)
                if !address.isEmpty { detail.append(address) }
                if includeReferences {
                    let reference = item.sourceConfirmation.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !reference.isEmpty { detail.append("Ref \(reference)") }
                }

                return StayRow(
                    id: item.clientUUID.uuidString,
                    name: item.title,
                    dates: dates,
                    nights: nights,
                    detail: detail.joined(separator: " · ")
                )
            }
    }

    // MARK: - Travel

    private static func buildTravel(
        _ items: [LocalItineraryItem],
        includeReferences: Bool
    ) -> [TravelRow] {
        items
            .filter { $0.kindEnum == .transport }
            .sorted { lhs, rhs in
                let lday = WallClock.startOfStoredDay(lhs.dayDate)
                let rday = WallClock.startOfStoredDay(rhs.dayDate)
                if lday != rday { return lday < rday }
                switch (lhs.startTime, rhs.startTime) {
                case (nil, nil): return lhs.sortOrder < rhs.sortOrder
                case (nil, _):   return true
                case (_, nil):   return false
                case let (l?, r?): return l < r
                }
            }
            .map { item in
                let meta = item.ticketMeta
                let origin = meta?.originCode?.trimmed ?? ""
                let destination = meta?.destinationCode?.trimmed ?? ""
                let route = (!origin.isEmpty && !destination.isEmpty)
                    ? "\(origin) → \(destination)"
                    : item.title

                // The title only earns its place when it says something the
                // route column does not. A stop titled "TR 280 · SIN→DPS" says
                // nothing new next to "SIN → DPS".
                var detail: [String] = []
                let titleEchoesRoute = !origin.isEmpty && !destination.isEmpty
                    && item.title.localizedCaseInsensitiveContains(origin)
                    && item.title.localizedCaseInsensitiveContains(destination)
                if route != item.title, !titleEchoesRoute {
                    detail.append(item.title)
                }
                if includeReferences {
                    let booking = bookingLine(item, avoiding: item.title)
                    if !booking.isEmpty { detail.append(booking) }
                }

                return TravelRow(
                    id: item.clientUUID.uuidString,
                    date: shortDay(WallClock.startOfStoredDay(item.dayDate)),
                    mode: kindLabel(item),
                    route: route,
                    times: timeRange(item),
                    detail: detail.joined(separator: " · ")
                )
            }
    }

    private static func timeRange(_ item: LocalItineraryItem) -> String {
        let format: (Date) -> String = { TimelineEntry.itineraryTimeFormatter.string(from: $0) }
        guard let departure = item.startTime else { return "Anytime" }
        if let arrival = item.arrivalTime { return "\(format(departure)) → \(format(arrival))" }
        return format(departure)
    }

    // MARK: - Kinds

    /// The mode for a transport stop, the kind otherwise. Same rule the
    /// timeline's own chip follows, so paper and screen name a stop alike.
    static func kindLabel(_ item: LocalItineraryItem) -> String {
        if item.kindEnum == .transport, let mode = item.transportModeEnum { return mode.displayName }
        return item.kindEnum.displayName
    }

    static func kindIcon(_ item: LocalItineraryItem) -> String {
        if item.kindEnum == .transport, let mode = item.transportModeEnum { return mode.icon }
        return item.kindEnum.icon
    }

    private static func buildKindCounts(_ items: [LocalItineraryItem]) -> [KindCount] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var icons: [String: String] = [:]

        for item in items {
            let label = kindLabel(item)
            if counts[label] == nil {
                order.append(label)
                icons[label] = kindIcon(item)
            }
            counts[label, default: 0] += 1
        }

        return order
            .map { label in
                KindCount(
                    id: label,
                    label: label,
                    count: counts[label] ?? 0,
                    icon: icons[label] ?? "mappin.and.ellipse"
                )
            }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Wording

    private static func scopeSentence(days: Int, stops: Int) -> String {
        let dayWord = days == 1 ? "day" : "days"
        return "Every stop on this trip, in the order it happens: \(stops) \(stopNoun(stops)) across \(days) \(dayWord)."
    }

    static let timeSentence =
        "Times read exactly as the booking states them, in local time at the stop."

    private static func omissionSentence(notes: Bool, references: Bool) -> String? {
        switch (notes, references) {
        case (true, true):   return nil
        case (false, true):  return "Personal notes are left out of this export."
        case (true, false):  return "Booking references, seats and gates are left out of this export."
        case (false, false): return "Personal notes, booking references, seats and gates are left out of this export."
        }
    }

    private static func stopWord(_ count: Int) -> String {
        "\(count) \(stopNoun(count))"
    }

    private static func stopNoun(_ count: Int) -> String {
        count == 1 ? "stop" : "stops"
    }

    // MARK: - Text

    /// Characters that fit one detail line under a stop: the printable width
    /// less the time column, at `.edCaption`. The ramp is bigger on the phone
    /// than on the Mac, so the budget is too — set it from the wrong one and
    /// SwiftUI truncates a line the wrap thought it had room for, which is how
    /// a note ends in "past the fount…" with another line still under it.
    #if os(macOS)
    static let detailBudget = 74
    #else
    static let detailBudget = 62
    #endif

    /// Greedy word wrap to a fixed line count, so a block's height is known
    /// before SwiftUI sees it. Overflow ends in an ellipsis rather than being
    /// cut mid-word, because a truncated address should look truncated.
    static func wrap(_ text: String, lines limit: Int, budget: Int = detailBudget) -> [String] {
        let flattened = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        guard !flattened.isEmpty, limit > 0, budget > 1 else { return [] }

        var all: [String] = []
        var current = ""

        for rawWord in flattened.split(separator: " ", omittingEmptySubsequences: true) {
            var word = String(rawWord)
            // A single word wider than a whole line is broken on the character.
            while word.count > budget {
                if !current.isEmpty { all.append(current); current = "" }
                all.append(String(word.prefix(budget)))
                word = String(word.dropFirst(budget))
            }
            if word.isEmpty { continue }

            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count <= budget {
                current = candidate
            } else {
                all.append(current)
                current = word
            }
        }
        if !current.isEmpty { all.append(current) }

        guard all.count > limit else { return all }
        var kept = Array(all.prefix(limit))
        kept[limit - 1] = String(kept[limit - 1].prefix(budget - 1))
            .trimmingCharacters(in: .whitespaces) + "…"
        return kept
    }

    // MARK: - Dates

    /// The trip's own range. The dates are anchored days (#506), so each one
    /// is read back as the device-local day naming it before it is formatted;
    /// formatting the anchor directly prints the day before, west of UTC.
    static func dateRange(_ start: Date, _ end: Date) -> String {
        TripExpenseReport.dateRange(
            WallClock.deviceDay(from: start),
            WallClock.deviceDay(from: end)
        )
    }

    /// "3 Jun" for an anchored day.
    static func shortDay(_ anchored: Date) -> String {
        TripExpenseReport.shortDay(WallClock.deviceDay(from: anchored))
    }

    /// "Italy itinerary 2026-09-14.pdf".
    static func fileName(tripName: String, on date: Date) -> String {
        ReportFileName.make(tripName: tripName, subject: "itinerary", on: date)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

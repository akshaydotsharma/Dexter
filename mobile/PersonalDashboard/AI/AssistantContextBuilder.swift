import Foundation
import SwiftData

/// Builds the EXISTING TASKS / NOTES / LISTS / FOLDERS section the LLM uses
/// to resolve "the dentist task" or "groceries list" to a concrete UUID.
/// Mirrors `fetchContext` + the `getInstructions` context block in
/// server/ai/chatToDrafts.js, just with UUIDs instead of integer IDs.
@MainActor
struct AssistantContextBuilder {
    let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    /// Convenience constructor for callers running on `MainActor` who want
    /// the shared singleton. Default-argument bindings can't read
    /// `SwiftDataStore.shared` (it's main-actor-isolated), so we bottle the
    /// dereference inside an explicit factory.
    static func `default`() -> AssistantContextBuilder {
        AssistantContextBuilder(store: .shared)
    }

    /// Render the context block exactly the way the server prompt embeds it,
    /// minus the leading newlines (the orchestrator concatenates).
    ///
    /// Trust model: every string sourced from SwiftData below is user data
    /// and is treated as untrusted by the LLM (see TRUST BOUNDARY in the
    /// system prompt). Strings flow through `safe(_:)` before being
    /// interpolated so an attacker who plants `"""` fences, ``` blocks, or
    /// the literal trust-boundary marker into a note can't escape the
    /// surrounding fence. See issue #134.
    func build() async -> String {
        let context = store.context
        var out = ""

        // Tasks: 50 most recent, undeleted.
        if let todos = try? context.fetch(
            FetchDescriptor<LocalTodo>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        ).prefix(50), !todos.isEmpty {
            out += "\n\nEXISTING TASKS:\n"
            out += todos.map { todo -> String in
                let id = Self.uuidString(todo.clientUUID)
                var line = "- ID:\(id) \"\(Self.safe(todo.title, maxLen: 200))\""
                if let due = todo.dueDate {
                    line += " (due: \(Self.dateOnly.string(from: due)))"
                }
                if let tag = todo.tag, !tag.isEmpty {
                    line += " [\(Self.safe(tag, maxLen: 50))]"
                }
                if todo.completed {
                    line += " ✓"
                }
                return line
            }.joined(separator: "\n")
        }

        // Notes: 50 most recent, sorted by updatedAt desc, with content preview.
        if let notes = try? context.fetch(
            FetchDescriptor<LocalNote>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        ).prefix(50), !notes.isEmpty {
            out += "\n\nEXISTING NOTES:\n"
            out += notes.map { note -> String in
                let id = Self.uuidString(note.clientUUID)
                let title = note.title ?? ""
                var line = "- ID:\(id) \"\(Self.safe(title, maxLen: 200))\""
                if let folderUUID = note.folderClientUUID {
                    line += " (folder ID:\(Self.uuidString(folderUUID)))"
                }
                if let raw = note.content, !raw.isEmpty {
                    let trimmed = String(raw.prefix(200))
                    let preview = trimmed.count >= 200
                        ? String(trimmed.prefix(197)) + "..."
                        : trimmed
                    line += "\n  Body preview: \"\(Self.safe(preview, maxLen: 220))\""
                }
                return line
            }.joined(separator: "\n")
        }

        // Lists: 50 most recent. Items are emitted with their indices so the
        // model can target edit_list_item / remove_list_item by index.
        if let lists = try? context.fetch(
            FetchDescriptor<LocalList>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        ).prefix(50), !lists.isEmpty {
            out += "\n\nEXISTING LISTS:\n"
            out += lists.map { list -> String in
                let id = Self.uuidString(list.clientUUID)
                let items = list.items
                var line = "- List ID:\(id) \"\(Self.safe(list.title, maxLen: 200))\" (\(items.count) items)"
                if !items.isEmpty {
                    line += "\n  Items:"
                    for (idx, item) in items.enumerated() {
                        line += "\n    [\(idx)] \"\(Self.safe(item.text, maxLen: 200))\""
                        if item.checked {
                            line += " ✓"
                        }
                    }
                }
                return line
            }.joined(separator: "\n")
        }

        // Folders: 20 most recent, sorted by name.
        if let folders = try? context.fetch(
            FetchDescriptor<LocalNoteFolder>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.name, order: .forward)]
            )
        ).prefix(20), !folders.isEmpty {
            out += "\n\nEXISTING FOLDERS:\n"
            out += folders.map { folder in
                "- ID:\(Self.uuidString(folder.clientUUID)) \"\(Self.safe(folder.name, maxLen: 100))\""
            }.joined(separator: "\n")
        }

        // Trips: 20 most-recently-updated. The 3 newest get a full day-by-day
        // breakdown; older trips only emit the header line to keep the prompt
        // budget reasonable. Match the EXISTING TASKS pattern: skip the
        // section entirely when there are zero trips.
        if let trips = try? context.fetch(
            FetchDescriptor<LocalTrip>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        ).prefix(20), !trips.isEmpty {
            // Pre-fetch every item once so we don't hit SwiftData N times.
            let allItems = (try? context.fetch(
                FetchDescriptor<LocalItineraryItem>(
                    sortBy: [SortDescriptor(\.dayDate, order: .forward),
                             SortDescriptor(\.sortOrder, order: .forward),
                             SortDescriptor(\.createdAt, order: .forward)]
                )
            )) ?? []
            let itemsByTrip = Dictionary(grouping: allItems, by: { $0.tripUUID })

            out += "\n\nEXISTING TRIPS:\n"
            out += trips.enumerated().map { (idx, trip) -> String in
                let id = Self.uuidString(trip.clientUUID)
                let startISO = Self.isoDate.string(from: trip.startDate)
                let endISO = Self.isoDate.string(from: trip.endDate)
                let days = max(1, Self.dayCount(from: trip.startDate, to: trip.endDate))
                let items = itemsByTrip[trip.clientUUID] ?? []

                var line = "- \(id) | \(Self.safe(trip.name, maxLen: 150)) | \(startISO) → \(endISO) (\(days) day\(days == 1 ? "" : "s")) | \(items.count) item\(items.count == 1 ? "" : "s")"

                // Full day-by-day breakdown only for the 3 most-recently-updated trips.
                if idx < 3, !items.isEmpty {
                    let groups = Dictionary(grouping: items, by: { $0.dayDate })
                    let sortedDays = groups.keys.sorted()
                    for day in sortedDays {
                        let dayItems = groups[day] ?? []
                        let dayNumber = Self.dayNumber(start: trip.startDate, day: day)
                        let dayISO = Self.isoDate.string(from: day)
                        let pretty = dayItems.map { item -> String in
                            let kind = ItineraryKind(rawValue: item.kind) ?? .activity
                            // For transport, surface the mode so the model can
                            // reference/edit it (e.g. "transport/train").
                            if kind == .transport, let mode = item.transportModeEnum {
                                return "\(Self.safe(item.title, maxLen: 120)) (\(kind.rawValue)/\(mode.rawValue))"
                            }
                            return "\(Self.safe(item.title, maxLen: 120)) (\(kind.rawValue))"
                        }.joined(separator: ", ")
                        line += "\n  Day \(dayNumber) (\(dayISO)): \(pretty)"
                    }
                }
                return line
            }.joined(separator: "\n")
        }

        // People / Events (#183): existing tags the model should reuse by
        // EXACT name when logging an expense, so "dinner with Sarah" links to
        // the existing Sarah instead of creating a near-duplicate. Names only —
        // the model passes person_name / event_name and the executor does the
        // find-or-create, so UUIDs aren't needed here. Skipped when empty.
        if let people = try? context.fetch(
            FetchDescriptor<LocalPerson>(sortBy: [SortDescriptor(\.name, order: .forward)])
        ), !people.isEmpty {
            out += "\n\nPEOPLE (reuse the exact name when an expense is for/with one of these):\n"
            out += people
                .prefix(50)
                .map { "- \(Self.safe($0.name, maxLen: 100))" }
                .joined(separator: "\n")
        }
        if let events = try? context.fetch(
            FetchDescriptor<LocalEvent>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        ), !events.isEmpty {
            out += "\n\nEVENTS (reuse the exact name when an expense belongs to one of these):\n"
            out += events
                .prefix(50)
                .map { "- \(Self.safe($0.name, maxLen: 120))" }
                .joined(separator: "\n")
        }

        // Expenses (Finance v1): up to 20 most-recent expenses from the
        // last 30 days plus this-month and per-category SGD totals. Keeps
        // the prompt budget reasonable while giving the model enough
        // visibility to answer "what did I spend on groceries last week"
        // questions and not double-log when the user repeats themselves.
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        if let last30Cutoff = cal.date(byAdding: .day, value: -30, to: now) {
            let cutoff = cal.startOfDay(for: last30Cutoff)
            if let recent = try? context.fetch(
                FetchDescriptor<LocalExpense>(
                    predicate: #Predicate { $0.date >= cutoff },
                    sortBy: [
                        SortDescriptor(\LocalExpense.date, order: .reverse),
                        SortDescriptor(\LocalExpense.createdAt, order: .reverse)
                    ]
                )
            ), !recent.isEmpty {
                // This-month total (calendar month).
                let monthComps = cal.dateComponents([.year, .month], from: now)
                let monthStart = cal.date(from: monthComps) ?? now
                let monthRows = recent.filter { $0.date >= monthStart }
                // Net refunds against spend (#206) so the figure the assistant
                // reports matches the Finance UI's netted totals.
                let monthTotal = monthRows.reduce(0.0) { $0 + $1.signedSGD }

                // Category totals this month, biggest first (refunds netted).
                var byCategory: [String: Double] = [:]
                for row in monthRows {
                    byCategory[row.category, default: 0] += row.signedSGD
                }
                let topCategories = byCategory
                    .sorted { $0.value > $1.value }
                    .prefix(5)

                out += "\n\nEXPENSES (this month, last 30):\n"
                out += String(format: "- This month total: SGD %.2f", monthTotal)
                if !topCategories.isEmpty {
                    let catLine = topCategories.map { (raw, total) -> String in
                        let display = ExpenseCategory(rawValue: raw)?.displayName ?? raw
                        return String(format: "%@: SGD %.2f", display, total)
                    }.joined(separator: ", ")
                    out += "\n- Top categories: \(catLine)"
                }

                let rows = recent.prefix(20)
                out += "\n- Recent:"
                for row in rows {
                    let dayISO = Self.isoDate.string(from: row.date)
                    let category = ExpenseCategory(rawValue: row.category)?.displayName ?? "Other"
                    var line = "\n  - \(dayISO) · "
                    if let merchant = row.merchant, !merchant.isEmpty {
                        line += Self.safe(merchant, maxLen: 120)
                    } else if let desc = row.expenseDescription, !desc.isEmpty {
                        line += Self.safe(desc, maxLen: 120)
                    } else {
                        line += category
                    }
                    line += String(format: " · SGD %.2f", row.sgdAmount)
                    if row.originalCurrency.uppercased() != "SGD" {
                        line += String(format: " (\(row.originalCurrency.uppercased()) %.2f)", row.originalAmount)
                    }
                    line += " · \(category)"
                    // Flag refunds so the assistant reads them as money-in, not
                    // spend — the amount above is a positive magnitude (#206).
                    if row.isRefund { line += " · refund (credit)" }
                    out += line
                }
            }
        }

        // Personal vocabulary: words the user has explicitly taught the
        // assistant so the model can prefer them over close-sounding
        // mistranscriptions ("envisso" vs. "in visa", "Dexter" vs. "Dexter
        // [unrelated]"). Emitted as XML-tagged so the prompt can refer to it
        // by name. Skipped entirely when empty so we don't ship a stub block.
        if let keywords = try? context.fetch(
            FetchDescriptor<LocalKeyword>(
                sortBy: [SortDescriptor(\.term, order: .forward)]
            )
        ), !keywords.isEmpty {
            out += "\n\n<personal_vocabulary>\n"
            out += keywords.map { keyword -> String in
                let safeTerm = Self.safe(keyword.term, maxLen: 80)
                let trimmedNotes = keyword.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedNotes.isEmpty {
                    return "- \(safeTerm)"
                }
                return "- \(safeTerm): \(Self.safe(trimmedNotes, maxLen: 200))"
            }.joined(separator: "\n")
            out += "\n</personal_vocabulary>"
        }

        return out
    }

    /// Compact list of EVERY trip for the email-to-itinerary matcher (#143).
    ///
    /// The chat/capture `build()` ranks trips by `updatedAt` and only fully
    /// details the top 3, which buries an upcoming-but-not-recently-edited
    /// trip and made the email matcher miss it. This method is deliberately
    /// different: it emits ALL trips (one compact line each: id, name, date
    /// range, item count), and orders them so the trips most likely to match a
    /// booking are first — ongoing/upcoming trips by start date, then past
    /// trips most-recent-first. No day-by-day breakdown is needed for matching
    /// by date + destination, so the prompt stays cheap even with many trips.
    ///
    /// Returns an empty string when there are no trips (caller short-circuits
    /// to a skip before this is ever called, but keep it total).
    func tripsForMatching() async -> String {
        let context = store.context
        guard let trips = try? context.fetch(
            FetchDescriptor<LocalTrip>(sortBy: [SortDescriptor(\.startDate, order: .forward)])
        ), !trips.isEmpty else {
            return ""
        }

        // Per-trip item counts in one fetch.
        let allItems = (try? context.fetch(FetchDescriptor<LocalItineraryItem>())) ?? []
        var countByTrip: [UUID: Int] = [:]
        for item in allItems { countByTrip[item.tripUUID, default: 0] += 1 }

        let today = Calendar(identifier: .gregorian).startOfDay(for: Date())

        // Upcoming/ongoing first (endDate >= today), by start date; then past
        // trips, most recent end first. Bookings almost always target a future
        // trip, so this puts the likely match at the top.
        let upcoming = trips.filter { $0.endDate >= today }
            .sorted { $0.startDate < $1.startDate }
        let past = trips.filter { $0.endDate < today }
            .sorted { $0.endDate > $1.endDate }
        let ordered = upcoming + past

        var out = "\n\nEXISTING TRIPS (match the email to ONE of these by date range AND destination):\n"
        out += ordered.map { trip -> String in
            let id = Self.uuidString(trip.clientUUID)
            let startISO = Self.isoDate.string(from: trip.startDate)
            let endISO = Self.isoDate.string(from: trip.endDate)
            let count = countByTrip[trip.clientUUID] ?? 0
            let tag = trip.endDate >= today ? "upcoming/ongoing" : "past"
            return "- \(id) | \(Self.safe(trip.name, maxLen: 150)) | \(startISO) → \(endISO) | \(count) item\(count == 1 ? "" : "s") | \(tag)"
        }.joined(separator: "\n")
        return out
    }

    /// Lower-cased UUID string. Matches Postgres' default uuid render so any
    /// future cross-checking against server logs lines up.
    private static func uuidString(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }

    /// Neutralise user-controlled text before embedding it in the system
    /// prompt. Defense in depth against indirect prompt injection (issue
    /// #134) — the system prompt's TRUST BOUNDARY section tells the LLM to
    /// ignore instructions in this data, and this helper additionally:
    ///
    /// - Collapses newlines (one-line fields can't run multi-line attacks)
    /// - Strips ASCII / Unicode control characters
    /// - Neutralises triple-backtick fences, "```", `"""`, and the literal
    ///   trust-boundary marker so an attacker can't escape the surrounding
    ///   fence or impersonate the prompt's own structure
    /// - Caps length so a single payload can't fill the prompt budget
    private static func safe(_ s: String, maxLen: Int = 500) -> String {
        // Drop control characters but keep tab/space — newlines become a
        // single space so titles/preview lines stay inline.
        let collapsed = s.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let scrubbed = String(collapsed.unicodeScalars.filter { scalar in
            // Keep tab (0x09), drop the rest of C0 and DEL.
            if scalar.value == 0x09 { return true }
            if scalar.value < 0x20 { return false }
            if scalar.value == 0x7F { return false }
            // Drop C1 control range too.
            if scalar.value >= 0x80 && scalar.value <= 0x9F { return false }
            return true
        }.map(Character.init))
        // Break out of any code-fence / docstring / boundary impersonation.
        let neutralised = scrubbed
            .replacingOccurrences(of: "```", with: "ʼʼʼ")
            .replacingOccurrences(of: "\"\"\"", with: "\u{201D}\u{201D}\u{201D}")
            .replacingOccurrences(of: "TRUST BOUNDARY", with: "trust boundary")
            .replacingOccurrences(of: "SYSTEM:", with: "system :")
            .replacingOccurrences(of: "ASSISTANT:", with: "assistant :")
        if neutralised.count > maxLen {
            return String(neutralised.prefix(maxLen - 1)) + "…"
        }
        return neutralised
    }

    /// Mirrors `new Date(due).toLocaleDateString()` from the server prompt:
    /// short date, no time, locale-respecting.
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    /// `yyyy-MM-dd` for trip start/end and per-day labels. Matches the
    /// "ISO date" shape the spec calls out for the EXISTING TRIPS block.
    private static let isoDate: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Inclusive day count between two `startOfDay`-normalised dates.
    private static func dayCount(from start: Date, to end: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.day], from: start, to: end)
        return (comps.day ?? 0) + 1
    }

    /// 1-indexed day number for a given day inside a trip ("Day 1" = startDate).
    private static func dayNumber(start: Date, day: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.day], from: start, to: day)
        return (comps.day ?? 0) + 1
    }
}

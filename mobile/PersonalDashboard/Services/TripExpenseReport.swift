import Foundation

/// The trip expense report, as data (#528).
///
/// Everything the exported PDF says lives here, already worded and already
/// formatted. There is no SwiftUI in this file and nothing on it needs the main
/// actor, so the whole report can be asserted in a test without rendering a
/// single view — which is the point, because the report's job is to agree with
/// the tab it was exported from.
///
/// Two rules shape the build:
///
/// 1. **Every figure comes from the existing math.** `TripSettlement.totals`,
///    `LocalExpense.signedSGD` / `signedOriginal`, and the caller's own money
///    formatters. Nothing is re-derived from raw fields, so a report can never
///    disagree with the screen.
/// 2. **The ledger narrows, the settlement does not.** The tab's people filter
///    chooses which expenses are listed. A net computed over a subset of the
///    bills is not a real debt, so the participant table, the transfers and the
///    totals all run over every expense on the trip, and the report says so.
struct TripExpenseReport {

    // MARK: - Sections

    struct Cover {
        let tripName: String
        let dateRange: String
        /// Every expense on the trip.
        let expenseCount: Int
        let groupTotal: String
        /// What each party consumed, user first. The same number the
        /// participant table calls Spent, repeated here deliberately: the
        /// question "what do I owe for this trip" has to be answerable from
        /// page one, without turning to the breakdown.
        let shares: [ShareRow]
        let scopeSentence: String
        let currencySentence: String
        /// Present only when some ledger row is written in a currency the
        /// report is not; nil when there is nothing to warn about.
        let ledgerCurrencyNote: String?
        let exportedOn: String
    }

    /// One party's consumed share, for the cover.
    struct ShareRow: Identifiable {
        let id: String
        let name: String
        let share: Double
        let shareText: String
    }

    struct LedgerRow: Identifiable {
        let id: String
        /// Short day stamp, repeated per row so a continuation page reads on
        /// its own ("3 Jun").
        let dateLabel: String
        /// Merchant, falling back to the description, then the category.
        let title: String
        let category: String
        /// Amount in the currency the expense was captured in, signed. A refund
        /// carries a leading minus and reads as a credit.
        let amount: String
        let isRefund: Bool
        /// "You paid" / "Priya paid" / "Someone paid".
        let payer: String
        /// "Your cost in full" / "Split evenly: You, Priya" / "Split: You ×2, Priya ×1".
        let split: String
    }

    struct LedgerDay: Identifiable {
        let id: String
        /// "Tue 3 Jun 2026".
        let title: String
        /// The day's own net total, in the report's currency.
        let total: String
        let rows: [LedgerRow]
    }

    struct ParticipantRow: Identifiable {
        let id: String
        let name: String
        /// What the party fronted, in the report's amount basis.
        let paid: Double
        /// Their consumed share of the bills.
        let spent: Double
        /// `paid - spent`. Positive means the group owes them.
        let net: Double
        let paidText: String
        let spentText: String
        let netText: String
    }

    struct TransferRow: Identifiable {
        let id: String
        /// Who hands the money over, and who receives it. Kept as parties, not
        /// just names, so the clearing property can be asserted directly
        /// against the participant table.
        let from: SplitPartyID
        let to: SplitPartyID
        /// "You pay Priya".
        let sentence: String
        let amount: Double
        let amountText: String
    }

    struct CategoryRow: Identifiable {
        let id: String
        let name: String
        let total: Double
        let count: Int
        /// 0...1 of the group total, for the bar.
        let share: Double
        let totalText: String
        /// "34%".
        let shareText: String
    }

    struct CurrencyRow: Identifiable {
        let id: String
        let code: String
        let total: Double
        let totalText: String
        /// "1 EUR = SGD 1.4730", or an empty string when the trip has no
        /// usable observation for the code.
        let rateText: String
    }

    // MARK: - The report

    let cover: Cover
    let ledger: [LedgerDay]
    /// Says what the ledger is a list of, so a page that does not carry the
    /// cover still stands on its own.
    let ledgerNote: String
    let participants: [ParticipantRow]
    let transfers: [TransferRow]
    let settlementNote: String
    /// "Settled in SGD · mixed currencies", or nil on a single-currency trip.
    let settlementCaveat: String?
    let categories: [CategoryRow]
    /// Empty when the trip has one capture currency that is already the
    /// report's currency, matching the tab's `showsCurrencyBreakdown`.
    let currencies: [CurrencyRow]
    /// The group total, in the report's amount basis. The category totals sum
    /// to this.
    let groupTotal: Double
    let reportCurrencyCode: String
    /// "Italy expenses 2026-09-14.pdf".
    let fileName: String
}

// MARK: - Input

/// Everything the report needs from the Expenses tab. The tab owns the filter
/// state and the money formatters, so it hands them over rather than having the
/// report reach for `FinanceSettings` itself — which is also what makes the
/// whole thing testable with plain values.
struct TripExpenseReportInput {
    let tripName: String
    let startDate: Date
    let endDate: Date

    /// Every expense on the trip, in the tab's order (newest first). Rows
    /// hidden from the trip are dropped again here, defensively: the tab's
    /// `@Query` predicate already excludes them, and they must appear nowhere.
    ///
    /// The report is the WHOLE trip. The tab's people filter narrows what is on
    /// screen and deliberately does not reach this: a ledger listing one
    /// person's bills beside a settlement computed over everyone's would be two
    /// documents stapled together, and the thing being sent to the group is the
    /// group's record.
    let allExpenses: [LocalExpense]

    /// [.me, .person(a), .person(b)] — the user then the trip's participants.
    let participantOrder: [SplitPartyID]

    /// The currency the whole report is written in, chosen at export time.
    let reportCurrencyCode: String

    let exportDate: Date

    /// "You" / a person's name / "Someone" for a person deleted from People.
    let displayName: (SplitPartyID) -> String

    /// Renders a home-currency (SGD) value in the report's currency. The tab's
    /// own `formatFiltered`, bound to the currency chosen for the export.
    let displayMoney: (Double) -> String

    /// Renders a value in a named capture currency. The tab's `formatOriginal`.
    let captureMoney: (Double, String) -> String

    /// The trip-observed rate (code → SGD) the tab converts with. Nil when the
    /// trip has no usable observation for the code.
    let tripRateToSGD: (String) -> Double?
}

// MARK: - Build

extension TripExpenseReport {

    static func make(_ input: TripExpenseReportInput) -> TripExpenseReport {
        // Belt and braces on #264: a row removed from the trip has no trip
        // surface, and the report is a trip surface.
        let all = input.allExpenses.filter { !$0.hiddenFromTrip }

        let code = input.reportCurrencyCode.uppercased()
        let captureCodes = Set(all.map { $0.originalCurrency.uppercased() })

        // The report settles in ONE currency throughout, and that currency is
        // the one chosen at export time. When the trip was captured entirely in
        // that currency there is nothing to convert, so the frozen capture
        // amounts are used directly and no rounding is introduced. Otherwise
        // the SGD basis converts, exactly as the settle-up card does on a
        // mixed-currency trip.
        let settlesNatively = captureCodes.count == 1 && captureCodes.first == code
        let basis: (LocalExpense) -> Double = settlesNatively
            ? { $0.signedOriginal }
            : { $0.signedSGD }
        let money: (Double) -> String = settlesNatively
            ? { input.captureMoney($0, code) }
            : input.displayMoney

        let groupTotal = all.reduce(0) { $0 + basis($1) }
        let totals = TripSettlement.totals(expenses: all, amount: basis)

        let ledger = buildLedger(
            rows: all,
            basis: basis,
            money: money,
            captureMoney: input.captureMoney,
            displayName: input.displayName
        )

        let participants = buildParticipants(
            totals: totals,
            order: input.participantOrder,
            money: money,
            displayName: input.displayName
        )

        let transfers = buildTransfers(
            participants: participants,
            money: money,
            displayName: input.displayName
        )

        let categories = buildCategories(rows: all, basis: basis, money: money, groupTotal: groupTotal)
        let currencies = buildCurrencies(
            rows: all,
            reportCode: code,
            captureMoney: input.captureMoney,
            tripRateToSGD: input.tripRateToSGD
        )

        // Built straight off the participant rows rather than re-read from
        // `totals`, so the cover cannot disagree with the table it repeats.
        let shares = participants.map { row in
            ShareRow(id: row.id, name: row.name, share: row.spent, shareText: row.spentText)
        }

        let cover = Cover(
            tripName: input.tripName,
            dateRange: Self.dateRange(input.startDate, input.endDate),
            expenseCount: all.count,
            groupTotal: money(groupTotal),
            shares: shares,
            scopeSentence: Self.scopeSentence(total: all.count),
            currencySentence: Self.currencySentence(code: code, settlesNatively: settlesNatively),
            ledgerCurrencyNote: settlesNatively ? nil : Self.ledgerCurrencyNote,
            exportedOn: Self.longDate(input.exportDate)
        )

        return TripExpenseReport(
            cover: cover,
            ledger: ledger,
            ledgerNote: Self.ledgerNote,
            participants: participants,
            transfers: transfers,
            settlementNote: Self.settlementNote,
            settlementCaveat: captureCodes.count > 1 ? "Settled in \(code) · mixed currencies" : nil,
            categories: categories,
            currencies: currencies,
            groupTotal: groupTotal,
            reportCurrencyCode: code,
            fileName: Self.fileName(tripName: input.tripName, on: input.exportDate)
        )
    }

    // MARK: - Ledger

    private static func buildLedger(
        rows: [LocalExpense],
        basis: (LocalExpense) -> Double,
        money: (Double) -> String,
        captureMoney: (Double, String) -> String,
        displayName: (SplitPartyID) -> String
    ) -> [LedgerDay] {
        // `LocalExpense.date` is written with `Calendar.current.startOfDay`
        // (ExpenseService), and Finance reads it the same way, so the report
        // groups the same way. Deliberately NOT the UTC day anchor, which
        // belongs to itinerary day fields only (#506).
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [LocalExpense]] = [:]

        for row in rows {
            let day = calendar.startOfDay(for: row.date)
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(row)
        }

        // Newest first, matching the tab's sort.
        order.sort(by: >)

        return order.map { day in
            let dayRows = buckets[day] ?? []
            let total = dayRows.reduce(0) { $0 + basis($1) }
            return LedgerDay(
                id: ISO8601DateFormatter().string(from: day),
                title: dayTitle(day),
                total: money(total),
                rows: dayRows.map { row in
                    ledgerRow(row, captureMoney: captureMoney, displayName: displayName)
                }
            )
        }
    }

    private static func ledgerRow(
        _ expense: LocalExpense,
        captureMoney: (Double, String) -> String,
        displayName: (SplitPartyID) -> String
    ) -> LedgerRow {
        let code = expense.originalCurrency.uppercased()
        let value = expense.signedOriginal
        // A refund carries a positive magnitude and a direction flag (#206).
        // It reads as a credit and its negative value nets the day down.
        let amount = value < 0
            ? "−" + captureMoney(-value, code)
            : captureMoney(value, code)

        let payer: SplitPartyID = expense.paidByPersonUUID.map { .person($0) } ?? .me

        return LedgerRow(
            id: expense.clientUUID,
            dateLabel: shortDay(expense.date),
            title: title(for: expense),
            category: expense.categoryEnum.displayName,
            amount: amount,
            isRefund: expense.isRefund,
            payer: "\(displayName(payer)) paid",
            split: splitText(for: expense, displayName: displayName)
        )
    }

    private static func title(for expense: LocalExpense) -> String {
        let merchant = expense.merchant?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let merchant, !merchant.isEmpty { return merchant }
        let description = expense.expenseDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let description, !description.isEmpty { return description }
        return expense.categoryEnum.displayName
    }

    /// How the bill was shared, in the same reading the settle-up math uses.
    ///
    /// An UNSPLIT expense is the USER's cost in full, whoever fronted it
    /// (#504, #512). The ledger prints that rather than "not split", so the row
    /// agrees with the settlement section on the same document: a bill Priya
    /// paid and nobody split is a debt the user owes her, and both sections say
    /// so.
    private static func splitText(
        for expense: LocalExpense,
        displayName: (SplitPartyID) -> String
    ) -> String {
        let entries = expense.splits.filter { $0.shares > 0 }
        let totalShares = entries.reduce(0) { $0 + $1.shares }
        guard !entries.isEmpty, totalShares > 0 else {
            return "Your cost in full"
        }

        let parts: [(name: String, shares: Int)] = entries.map { entry in
            let party: SplitPartyID = entry.personID.map { .person($0) } ?? .me
            return (displayName(party), entry.shares)
        }

        if parts.count == 1 {
            let only = parts[0].name
            return only == "You" ? "Your cost in full" : "\(only)'s cost in full"
        }
        if Set(parts.map(\.shares)).count == 1 {
            return "Split evenly: " + parts.map(\.name).joined(separator: ", ")
        }
        return "Split: " + parts.map { "\($0.name) ×\($0.shares)" }.joined(separator: ", ")
    }

    // MARK: - Participants

    private static func buildParticipants(
        totals: [SplitPartyID: (paid: Double, owed: Double)],
        order: [SplitPartyID],
        money: (Double) -> String,
        displayName: (SplitPartyID) -> String
    ) -> [ParticipantRow] {
        // The trip's roster first, so a participant who spent nothing still
        // gets a row and the table reads as the whole group. Then anyone the
        // expenses know about who is no longer on the roster — a person deleted
        // from People still holds a slice of a bill, and dropping them would
        // make the table stop summing to the group total.
        var parties = order
        for party in totals.keys where !parties.contains(party) {
            parties.append(party)
        }
        let extras = parties.dropFirst(order.count).sorted { $0.stableKey < $1.stableKey }
        parties = order + extras

        return parties.map { party in
            let entry = totals[party] ?? (paid: 0, owed: 0)
            let net = entry.paid - entry.owed
            return ParticipantRow(
                id: party.stableKey,
                name: displayName(party),
                paid: entry.paid,
                spent: entry.owed,
                net: net,
                paidText: money(entry.paid),
                spentText: money(entry.owed),
                netText: (net < 0 ? "−" : "") + money(abs(net))
            )
        }
    }

    // MARK: - Transfers

    private static func buildTransfers(
        participants: [ParticipantRow],
        money: (Double) -> String,
        displayName: (SplitPartyID) -> String
    ) -> [TransferRow] {
        var balances: [SplitPartyID: Double] = [:]
        var names: [String: String] = [:]
        for row in participants {
            let party = Self.party(fromStableKey: row.id)
            balances[party] = row.net
            names[row.id] = row.name
        }

        return TripTransferSolver.transfers(balances: balances).enumerated().map { index, transfer in
            let from = names[transfer.from.stableKey] ?? displayName(transfer.from)
            let to = names[transfer.to.stableKey] ?? displayName(transfer.to)
            // "You pay Priya" reads better than "You pays Priya".
            let verb = from == "You" ? "pay" : "pays"
            return TransferRow(
                id: "\(index)-\(transfer.from.stableKey)-\(transfer.to.stableKey)",
                from: transfer.from,
                to: transfer.to,
                sentence: "\(from) \(verb) \(to)",
                amount: transfer.amount,
                amountText: money(transfer.amount)
            )
        }
    }

    private static func party(fromStableKey key: String) -> SplitPartyID {
        guard let id = UUID(uuidString: key) else { return .me }
        return .person(id)
    }

    // MARK: - Categories

    private static func buildCategories(
        rows: [LocalExpense],
        basis: (LocalExpense) -> Double,
        money: (Double) -> String,
        groupTotal: Double
    ) -> [CategoryRow] {
        var totals: [ExpenseCategory: (total: Double, count: Int)] = [:]
        for row in rows {
            var entry = totals[row.categoryEnum] ?? (0, 0)
            entry.total += basis(row)
            entry.count += 1
            totals[row.categoryEnum] = entry
        }

        return totals
            .map { category, entry -> CategoryRow in
                let share = abs(groupTotal) > 0.0001 ? entry.total / groupTotal : 0
                return CategoryRow(
                    id: category.rawValue,
                    name: category.displayName,
                    total: entry.total,
                    count: entry.count,
                    share: min(max(share, 0), 1),
                    totalText: money(entry.total),
                    shareText: "\(Int((share * 100).rounded()))%"
                )
            }
            .sorted { lhs, rhs in
                if abs(lhs.total - rhs.total) > 0.0001 { return lhs.total > rhs.total }
                return lhs.name < rhs.name
            }
    }

    // MARK: - Currencies

    private static func buildCurrencies(
        rows: [LocalExpense],
        reportCode: String,
        captureMoney: (Double, String) -> String,
        tripRateToSGD: (String) -> Double?
    ) -> [CurrencyRow] {
        var totals: [String: Double] = [:]
        for row in rows {
            totals[row.originalCurrency.uppercased(), default: 0] += row.signedOriginal
        }
        // Nothing to add when the trip has a single currency that is already
        // the one the report is written in — the group total already says it.
        if totals.count == 1, totals.keys.first == reportCode { return [] }

        return totals
            .map { code, total -> CurrencyRow in
                let rate = tripRateToSGD(code)
                let rateText: String = {
                    guard let rate, rate.isFinite, rate > 0 else { return "" }
                    if code == "SGD" { return "" }
                    return String(format: "1 %@ = SGD %.4f", code, rate)
                }()
                return CurrencyRow(
                    id: code,
                    code: code,
                    total: total,
                    totalText: captureMoney(total, code),
                    rateText: rateText
                )
            }
            .sorted { abs($0.total) > abs($1.total) }
    }

    // MARK: - Wording

    /// The report is the whole trip, every section of it. Nothing here
    /// contrasts a filter, because nothing in the report is filtered.
    private static func scopeSentence(total: Int) -> String {
        "This report covers all \(total) \(expenseWord(total)) on this trip, for everyone on it."
    }

    private static let ledgerNote = "Every expense on this trip, newest first."

    private static let settlementNote =
        "Paid is what each person fronted. Spent is their share of the bills. Net is the difference."

    static let ledgerCurrencyNote =
        "Ledger rows keep the currency they were captured in."

    private static func currencySentence(code: String, settlesNatively: Bool) -> String {
        if settlesNatively {
            return "Every amount is in \(code), the currency the trip was captured in."
        }
        return "Every amount is in \(code), the currency chosen for this export, converted with the rates frozen on this trip's expenses."
    }

    private static func expenseWord(_ count: Int) -> String {
        count == 1 ? "expense" : "expenses"
    }

    // MARK: - Dates

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate(format)
        return formatter
    }

    static func dateRange(_ start: Date, _ end: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: end) { return longDate(start) }
        if calendar.component(.year, from: start) == calendar.component(.year, from: end) {
            let short = formatter("dMMM")
            return "\(short.string(from: start)) – \(longDate(end))"
        }
        return "\(longDate(start)) – \(longDate(end))"
    }

    static func longDate(_ date: Date) -> String {
        formatter("dMMMyyyy").string(from: date)
    }

    static func dayTitle(_ date: Date) -> String {
        formatter("EEEdMMMyyyy").string(from: date)
    }

    static func shortDay(_ date: Date) -> String {
        formatter("dMMM").string(from: date)
    }

    /// "Italy expenses 2026-09-14.pdf". Anything a file system would object to
    /// is collapsed, so a trip called "Rome / Milan" still saves.
    static func fileName(tripName: String, on date: Date) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd"

        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = tripName
            .components(separatedBy: illegal)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let name = cleaned.isEmpty ? "Trip" : cleaned
        return "\(name) expenses \(stamp.string(from: date)).pdf"
    }
}

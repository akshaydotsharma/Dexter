import SwiftUI
import SwiftData

/// Single-row presentation of a `LocalExpense`. Tap → edit (handler passed
/// in by the parent so we don't couple the row to a sheet binding).
struct ExpenseRow: View {
    let expense: LocalExpense
    let onTap: () -> Void

    /// People, so a tagged expense's chip renders in that person's colour.
    /// Cheap (people are few) and keeps the row's chip accurate without
    /// denormalising the colour onto every expense.
    @Query(sort: [SortDescriptor(\LocalPerson.name, order: .forward)])
    private var people: [LocalPerson]

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: expense.categoryEnum.sfSymbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Tokens.accentFinance)
                .frame(width: 36, height: 36)
                .background(Tokens.paper2, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryLine)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                if let secondary = secondaryLine {
                    Text(secondary)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(1)
                }
                // Statement attribution (#189): which imported statement this
                // row came off, e.g. "May 2026 Citi - 1234". Only shown for
                // statement-sourced rows that captured a header — a small
                // secondary caption that never clutters other rows.
                if let statement = expense.statementLabel.trimmedNonEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 9, weight: .regular))
                        Text(statement)
                            .lineLimit(1)
                    }
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                }
                if hasBadges {
                    badgeRow
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                // Refunds are money coming IN: shown in the success (green)
                // colour with a leading "+" so they read as a credit against
                // spend, distinct from a normal debit (#206).
                Text(sgdAmountLabel)
                    .font(.edBodyMedium)
                    .monospacedDigit()
                    .foregroundStyle(expense.isRefund ? Tokens.success : Tokens.ink)
                if showsOriginalAmount {
                    Text(originalAmountLabel)
                        .font(.edCaption)
                        .monospacedDigit()
                        .foregroundStyle(expense.isRefund ? Tokens.success.opacity(0.8) : Tokens.mutedSoft)
                }
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm + 2)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .paperBorder(Tokens.border, radius: 26)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Person / Event badges (#183)

    private var personLabel: String? {
        expense.personName?.trimmedNonEmpty
    }

    private var eventLabel: String? {
        expense.eventName?.trimmedNonEmpty
    }

    private var hasTags: Bool {
        personLabel != nil || eventLabel != nil
    }

    /// Whether any badge (person, event, or split) should render on the
    /// secondary badge row.
    private var hasBadges: Bool {
        hasTags || expense.isSplit || expense.isGroupSplit
    }

    /// Split badge label, e.g. "1/3 of SGD 90.00" (#188). Shows the user's
    /// fraction of the derived receipt total in SGD so it lines up with the
    /// primary SGD amount above it.
    private var splitLabel: String {
        "1/\(expense.numberOfShares) of \(FinanceDashboardBand.formatMoney(expense.receiptTotalSGD))"
    }

    /// The tagged person's chip colour, resolved from the live person record
    /// (matched by FK, falling back to name). Defaults to the finance accent
    /// if the person was deleted but its denormalised name survives on the row.
    private var personTint: Color {
        if let uuid = expense.personUUID,
           let person = people.first(where: { $0.clientUUID == uuid }) {
            return Color(personHex: person.colorHex)
        }
        if let name = personLabel,
           let person = people.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
            return Color(personHex: person.colorHex)
        }
        return Tokens.accentFinance
    }

    private var badgeRow: some View {
        HStack(spacing: Space.xs) {
            if let personLabel {
                PersonEventBadge(kind: .person, label: personLabel, tint: personTint)
            }
            if let eventLabel {
                PersonEventBadge(kind: .event, label: eventLabel)
            }
            if expense.isSplit {
                splitBadge
            }
            if expense.isGroupSplit {
                groupSplitBadge
            }
        }
    }

    /// Group-split badge (#258). The row's primary amount shows the FULL bill
    /// (that's how trip splits store `sgdAmount`), so this badge surfaces the
    /// user's own share alongside it — "your S$45.00 of S$135.00" — mirroring
    /// how the finance dashboard now counts only the user's share. Renders only
    /// for the full settle-up model (`splitsData` set), never for existing rows.
    private var groupSplitBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(groupSplitLabel)
                .font(.edCaption)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(Tokens.muted)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Tokens.muted.opacity(0.12), in: Capsule())
        .accessibilityLabel("Split expense, \(groupSplitLabel)")
    }

    private var groupSplitLabel: String {
        "your \(FinanceDashboardBand.formatMoney(abs(expense.myShareSGD))) of \(FinanceDashboardBand.formatMoney(expense.sgdAmount))"
    }

    /// Split badge (#188). Same capsule shape as `PersonEventBadge` but muted
    /// (it's a factual annotation, not a colour-coded tag), with a split-bill
    /// glyph and the "your share of receipt total" label.
    private var splitBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(splitLabel)
                .font(.edCaption)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(Tokens.muted)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Tokens.muted.opacity(0.12), in: Capsule())
        .accessibilityLabel("Split \(expense.numberOfShares) ways, your \(splitLabel)")
    }

    private var primaryLine: String {
        if let merchant = expense.merchant?.trimmedNonEmpty {
            return merchant
        }
        if let description = expense.expenseDescription?.trimmedNonEmpty {
            return description
        }
        return expense.categoryEnum.displayName
    }

    /// Secondary line: category name (if not already the primary) +
    /// description (if not already the primary).
    private var secondaryLine: String? {
        var pieces: [String] = []

        // Always show the category as a kind of tag-line — unless the
        // primary already IS the category fallback.
        let isCategoryPrimary = expense.merchant?.trimmedNonEmpty == nil &&
                                expense.expenseDescription?.trimmedNonEmpty == nil
        if !isCategoryPrimary {
            pieces.append(expense.categoryEnum.displayName)
        }

        // If both merchant and description exist, surface description on
        // the secondary line. Otherwise leave it.
        if let _ = expense.merchant?.trimmedNonEmpty,
           let description = expense.expenseDescription?.trimmedNonEmpty {
            pieces.append(description)
        }

        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    /// Primary SGD amount, with a leading "+" for refunds so a credit is
    /// unmistakable at a glance (the colour alone isn't enough for the
    /// colour-blind, and "+" carries the meaning in VoiceOver too) (#206).
    private var sgdAmountLabel: String {
        let base = FinanceDashboardBand.formatMoney(expense.sgdAmount)
        return expense.isRefund ? "+\(base)" : base
    }

    /// Show the original-currency sub-label whenever the expense was captured
    /// in a currency other than the one we're displaying totals in. Previously
    /// hardcoded against "SGD"; now compares against the chosen display
    /// currency so, e.g., a USD expense shown while the display currency is USD
    /// hides the redundant sub-label, and an SGD expense shown while displaying
    /// EUR surfaces the "SGD …" original.
    private var showsOriginalAmount: Bool {
        expense.originalCurrency.uppercased() != FinanceSettings.displayCurrencyCode.uppercased()
    }

    private var originalAmountLabel: String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.numberStyle = .decimal
        let amount = formatter.string(from: NSNumber(value: expense.originalAmount)) ?? "\(expense.originalAmount)"
        let base = "\(expense.originalCurrency.uppercased()) \(amount)"
        return expense.isRefund ? "+\(base)" : base
    }

    private var accessibilityLabel: String {
        let amountSpoken = expense.isRefund
            ? "refund \(FinanceDashboardBand.formatMoney(expense.sgdAmount))"
            : FinanceDashboardBand.formatMoney(expense.sgdAmount)
        var pieces: [String] = [primaryLine, amountSpoken, expense.categoryEnum.displayName]
        if showsOriginalAmount {
            pieces.append("\(originalAmountLabel) original")
        }
        if let statement = expense.statementLabel.trimmedNonEmpty {
            pieces.append("from \(statement)")
        }
        if let personLabel { pieces.append("for \(personLabel)") }
        if let eventLabel { pieces.append("event \(eventLabel)") }
        if expense.isSplit { pieces.append("split \(expense.numberOfShares) ways, your \(splitLabel)") }
        return pieces.joined(separator: ", ") + ". Tap to edit."
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

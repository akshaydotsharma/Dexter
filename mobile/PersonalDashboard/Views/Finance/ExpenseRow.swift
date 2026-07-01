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
                if hasTags {
                    tagBadges
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(FinanceDashboardBand.formatSGD(expense.sgdAmount))
                    .font(.edBodyMedium)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.ink)
                if expense.originalCurrency.uppercased() != "SGD" {
                    Text(originalAmountLabel)
                        .font(.edCaption)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.mutedSoft)
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

    private var tagBadges: some View {
        HStack(spacing: Space.xs) {
            if let personLabel {
                PersonEventBadge(kind: .person, label: personLabel, tint: personTint)
            }
            if let eventLabel {
                PersonEventBadge(kind: .event, label: eventLabel)
            }
        }
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

    private var originalAmountLabel: String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.numberStyle = .decimal
        let amount = formatter.string(from: NSNumber(value: expense.originalAmount)) ?? "\(expense.originalAmount)"
        return "\(expense.originalCurrency.uppercased()) \(amount)"
    }

    private var accessibilityLabel: String {
        var pieces: [String] = [primaryLine, FinanceDashboardBand.formatSGD(expense.sgdAmount), expense.categoryEnum.displayName]
        if expense.originalCurrency.uppercased() != "SGD" {
            pieces.append("\(originalAmountLabel) original")
        }
        if let personLabel { pieces.append("for \(personLabel)") }
        if let eventLabel { pieces.append("event \(eventLabel)") }
        return pieces.joined(separator: ", ") + ". Tap to edit."
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

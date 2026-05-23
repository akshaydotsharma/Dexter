import SwiftUI

/// Single-row presentation of a `LocalExpense`. Tap → edit (handler passed
/// in by the parent so we don't couple the row to a sheet binding).
struct ExpenseRow: View {
    let expense: LocalExpense
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Space.md) {
                Image(systemName: expense.categoryEnum.sfSymbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Tokens.accentFinance)
                    .frame(width: 36, height: 36)
                    .background(Tokens.paper2, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
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
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
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
        return pieces.joined(separator: ", ") + ". Tap to edit."
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

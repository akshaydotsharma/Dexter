import SwiftUI
import SwiftData

/// Add / edit form for a recurring-expense template (#236). Mirrors
/// `AddExpenseSheet`'s field styling (eyebrow labels, paper surfaces, finance
/// accent) and adds the recurring-only controls: day-of-month, active toggle,
/// and an optional end date. Nil `template` = create; otherwise edit in place.
///
/// Edits and deletes only affect FUTURE postings — already-posted expenses are
/// ordinary `LocalExpense` rows and are never revisited.
struct RecurringExpenseEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The template being edited, or nil to create a new one.
    let template: RecurringExpense?

    @State private var amountText: String = ""
    @State private var currency: String = FinanceSettings.displayCurrencyCode
    @State private var category: ExpenseCategory = .subscriptions
    @State private var merchant: String = ""
    @State private var descriptionField: String = ""
    @State private var paymentMethod: String = ""
    @State private var dayOfMonth: Int = 1
    @State private var isActive: Bool = true
    @State private var hasEndDate: Bool = false
    @State private var endDate: Date = Date()

    @State private var loaded: Bool = false
    @State private var saving: Bool = false
    @State private var errorMessage: String?

    @FocusState private var amountFocused: Bool

    private var isEditing: Bool { template != nil }

    private var amountValue: Double {
        Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var canSave: Bool { amountValue > 0 && !saving }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        amountField
                        categoryField
                        dayOfMonthField
                        merchantField
                        descriptionFieldView
                        paymentField
                        endDateField
                        if isEditing { activeField }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.edFootnote)
                                .foregroundStyle(Tokens.danger)
                                .padding(.top, Space.sm)
                        }
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle(isEditing ? "Edit recurring" : "New recurring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                    .foregroundStyle(canSave ? Tokens.ink : Tokens.muted)
                }
            }
        }
        .onAppear { loadIfNeeded() }
    }

    // MARK: - Fields

    private var amountField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Monthly amount").eyebrow()
            HStack(spacing: Space.sm) {
                TextField("0.00", text: $amountText)
                    .keyboardType(.decimalPad)
                    .font(.edDisplay)
                    .foregroundStyle(Tokens.ink)
                    .focused($amountFocused)
                    .padding(.vertical, Space.sm)
                    .padding(.horizontal, Space.md)
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                    .paperBorder(Tokens.border, radius: Radius.md)

                Menu {
                    ForEach(SupportedCurrency.all, id: \.self) { code in
                        Button(code) { currency = code }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currency)
                            .font(.edBodyMedium)
                            .foregroundStyle(Tokens.ink)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Tokens.muted)
                    }
                    .padding(.horizontal, Space.md)
                    .frame(height: 52)
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                    .paperBorder(Tokens.border, radius: Radius.md)
                }
                .accessibilityLabel("Currency")
            }
        }
    }

    private var categoryField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Category").eyebrow()
            Menu {
                ForEach(ExpenseCategory.allCases) { cat in
                    Button {
                        category = cat
                    } label: {
                        Label(cat.displayName, systemImage: cat.sfSymbol)
                    }
                }
            } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: category.sfSymbol)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Tokens.accentFinance)
                        .frame(width: 24)
                    Text(category.displayName)
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tokens.muted)
                }
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
            }
            .accessibilityLabel("Category")
        }
    }

    private var dayOfMonthField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Posts on").eyebrow()
            Menu {
                ForEach(1...31, id: \.self) { day in
                    Button(Self.ordinalLabel(day)) { dayOfMonth = day }
                }
            } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Tokens.accentFinance)
                        .frame(width: 24)
                    Text("The \(Self.ordinal(dayOfMonth)) of each month")
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tokens.muted)
                }
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
            }
            .accessibilityLabel("Posts on the \(Self.ordinal(dayOfMonth)) of each month")

            if dayOfMonth > 28 {
                Text("Months shorter than \(dayOfMonth) days post on the last day.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .padding(.horizontal, Space.xs)
            }
        }
    }

    private var merchantField: some View {
        labeledTextField(
            label: "Merchant",
            placeholder: "e.g. Landlord, Netflix",
            text: $merchant,
            optional: true
        )
    }

    private var descriptionFieldView: some View {
        labeledTextField(
            label: "Description",
            placeholder: "e.g. monthly rent",
            text: $descriptionField,
            optional: true
        )
    }

    private var paymentField: some View {
        labeledTextField(
            label: "Payment method",
            placeholder: "GIRO, Visa **1234, …",
            text: $paymentMethod,
            optional: true
        )
    }

    private var endDateField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text("End date").eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                Toggle("Stop after a date", isOn: $hasEndDate.animation())
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .tint(Tokens.accentFinance)
                if hasEndDate {
                    DatePicker("Last posting on or before", selection: $endDate, displayedComponents: .date)
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.inkSoft)
                        .tint(Tokens.accentFinance)
                }
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private var activeField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Status").eyebrow()
            Toggle(isActive ? "Active" : "Paused", isOn: $isActive)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .tint(Tokens.accentFinance)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private func labeledTextField(label: String, placeholder: String, text: Binding<String>, optional: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text(label).eyebrow()
                if optional {
                    Spacer()
                    Text("Optional")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                }
            }
            TextField(placeholder, text: text)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    // MARK: - Load + save

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        guard let template else {
            // New template: focus the amount field once the sheet settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { amountFocused = true }
            return
        }
        amountText = formatAmountForEdit(template.amount)
        currency = template.currency
        category = template.categoryEnum
        merchant = template.merchant ?? ""
        descriptionField = template.expenseDescription ?? ""
        paymentMethod = template.paymentMethod ?? ""
        dayOfMonth = min(max(template.dayOfMonth, 1), 31)
        isActive = template.isActive
        if let end = template.endDate {
            hasEndDate = true
            endDate = end
        }
    }

    private func save() async {
        guard amountValue > 0 else {
            errorMessage = "Enter an amount greater than zero."
            return
        }
        saving = true
        errorMessage = nil
        defer { saving = false }

        let service = RecurringExpenseService.default()
        do {
            if let template {
                try service.update(
                    template,
                    amount: amountValue,
                    currency: currency,
                    category: category,
                    merchant: merchant,
                    expenseDescription: descriptionField,
                    paymentMethod: paymentMethod,
                    dayOfMonth: dayOfMonth,
                    isActive: isActive,
                    startDate: nil,
                    endDate: .some(hasEndDate ? endDate : nil)
                )
            } else {
                _ = try service.create(
                    amount: amountValue,
                    currency: currency,
                    category: category,
                    merchant: merchant,
                    expenseDescription: descriptionField,
                    paymentMethod: paymentMethod,
                    dayOfMonth: dayOfMonth,
                    isActive: true,
                    startDate: Date(),
                    endDate: hasEndDate ? endDate : nil
                )
            }
            // Post immediately if this month's day has already passed. No banner:
            // the user is right here and sees the list update. Any posted row is
            // idempotent on re-runs.
            _ = await service.materialize(notify: false)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatAmountForEdit(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // MARK: - Ordinal helpers

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11, _), (12, _), (13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    static func ordinalLabel(_ n: Int) -> String {
        n == 31 ? "31st (or last day)" : ordinal(n)
    }
}

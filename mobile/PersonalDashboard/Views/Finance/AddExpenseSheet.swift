import SwiftUI
import SwiftData
import PDFKit
import UIKit

/// Editor target for the AddExpense / EditExpense sheet.
///
/// - `.new`: blank form, source defaults to `.manual`.
/// - `.existing(uuid)`: load by clientUUID, preserve receipt + source.
/// - `.prefilled(PrefilledExpense)`: seed fields from a scan/photo/PDF
///   capture (receipt already saved to disk; Vision may have failed).
enum ExpenseEditorTarget: Identifiable, Hashable {
    case new
    case existing(String)
    case prefilled(PrefilledExpense)

    var id: String {
        switch self {
        case .new:                return "new"
        case .existing(let uuid): return "existing:\(uuid)"
        case .prefilled(let p):   return "prefilled:\(p.receiptImagePath)"
        }
    }
}

/// AddExpense / EditExpense form. One sheet handles create, edit, and
/// "create-from-scanned-receipt" keyed off `target`. FX conversion runs
/// on save (cached so it doesn't block on the home currency).
struct AddExpenseSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let target: ExpenseEditorTarget

    @State private var amountText: String = ""
    @State private var currency: String = FinanceSettings.displayCurrencyCode
    @State private var category: ExpenseCategory = .other
    @State private var date: Date = Date()
    @State private var merchant: String = ""
    @State private var descriptionField: String = ""
    @State private var paymentMethod: String = ""

    /// Person / Event tags (#183). Nil = untagged. Held as resolved
    /// (uuid, name) pairs so save can stamp both the FK and the denormalised
    /// name. On edit these seed from the row's stored uuid/name.
    @State private var selectedPerson: ExpenseTag?
    @State private var selectedEvent: ExpenseTag?
    @State private var showingPersonPicker: Bool = false
    @State private var showingEventPicker: Bool = false

    /// How many people the bill is split among (#188). The amount field holds
    /// the RECEIPT TOTAL; on save we divide by this to get the stored per-share
    /// amount. Default 1 = not split. Clamped to 1...50 by the stepper.
    @State private var numberOfShares: Int = 1

    /// Where this expense will be tagged as having come from. Defaults to
    /// `.manual` for `.new`; carried over from the existing row on edit;
    /// set by `PrefilledExpense.source` on prefill.
    @State private var source: ExpenseSource = .manual

    /// Relative path under `Documents/`. Non-nil if a receipt is attached.
    @State private var receiptImagePath: String?

    /// Statement attribution (#189), e.g. "May 2026 Citi - 1234". Read-only —
    /// set only when editing an expense that was imported from a statement;
    /// shown as a small caption so the user can see which statement it came
    /// off. Empty for every other source.
    @State private var statementLabel: String = ""

    /// Banner state when the user came in from a failed extraction.
    @State private var extractionBanner: String?

    /// Self-reported confidence from the model. Shown as a subtle hint when
    /// `.low` so the user double-checks the amount.
    @State private var extractionConfidence: ExtractedExpense.Confidence?

    /// Full-size receipt viewer flag.
    @State private var showingReceiptViewer: Bool = false

    @State private var loaded: Bool = false
    @State private var saving: Bool = false
    @State private var errorMessage: String?

    @FocusState private var amountFocused: Bool

    private var isEditing: Bool {
        if case .existing = target { return true }
        return false
    }

    private var amountValue: Double {
        Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// The user's per-person share of the entered receipt total (#188). This
    /// is what gets stored as `originalAmount`. Equal-split only in v1.
    private var perShareValue: Double {
        amountValue / Double(max(numberOfShares, 1))
    }

    private var canSave: Bool {
        amountValue > 0 && !saving
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        if let extractionBanner {
                            banner(extractionBanner)
                        }
                        if receiptImagePath != nil {
                            receiptThumbnail
                        }
                        amountField
                        if extractionConfidence == .low {
                            confidenceHint
                        }
                        categoryField
                        dateField
                        merchantField
                        descriptionFieldView
                        paymentField
                        if let statement = statementLabel.trimmedNonEmpty {
                            statementAttribution(statement)
                        }
                        personField
                        eventField
                        sharesField

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
            .navigationTitle(navigationTitleText)
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
        .sheet(isPresented: $showingReceiptViewer) {
            if let path = receiptImagePath {
                ReceiptFullViewer(relativePath: path)
            }
        }
        .sheet(isPresented: $showingPersonPicker) {
            PersonPickerSheet(selection: $selectedPerson)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingEventPicker) {
            EventPickerSheet(selection: $selectedEvent)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear { loadIfNeeded() }
    }

    private var navigationTitleText: String {
        switch target {
        case .new:                return "New expense"
        case .existing:           return "Edit expense"
        case .prefilled:          return "Review expense"
        }
    }

    // MARK: - Banner + confidence hint

    private func banner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Tokens.warning)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("We saved your receipt")
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                Text(message)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .background(Tokens.warningSoft, in: RoundedRectangle(cornerRadius: Radius.md))
        .paperBorder(Tokens.warning.opacity(0.35), radius: Radius.md)
    }

    private var confidenceHint: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Tokens.muted)
            Text("Low confidence on the total — double-check the amount.")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
        }
        .padding(.horizontal, Space.xs)
    }

    // MARK: - Receipt thumbnail

    private var receiptThumbnail: some View {
        HStack(spacing: Space.md) {
            ReceiptThumbnailImage(relativePath: receiptImagePath)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .onTapGesture { showingReceiptViewer = true }
                .accessibilityLabel("View full receipt")

            VStack(alignment: .leading, spacing: 2) {
                Text("Receipt attached")
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                Text("Tap to view")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
            }
            Spacer()
            Button {
                removeReceipt()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Tokens.danger)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove receipt")
        }
        .padding(Space.md)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    private func removeReceipt() {
        guard let path = receiptImagePath else { return }
        try? ReceiptStorage.shared.delete(relativePath: path)
        receiptImagePath = nil
        // If we still have the prefilled banner up, hide it — the user has
        // chosen to start over without the receipt context.
        extractionBanner = nil
    }

    // MARK: - Fields

    private var amountField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Amount").eyebrow()
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

    private var dateField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Date").eyebrow()
            HStack {
                Text("When did this happen?")
                    .font(.edBody)
                    .foregroundStyle(Tokens.inkSoft)
                Spacer()
                DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .tint(Tokens.accentFinance)
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private var merchantField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text("Merchant").eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            TextField("e.g. Starbucks", text: $merchant)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private var descriptionFieldView: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text("Description").eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            TextField("Lunch with Sarah", text: $descriptionField)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private var paymentField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text("Payment method").eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            TextField("Cash, Visa **1234, …", text: $paymentMethod)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    /// Read-only statement attribution caption (#189). Mirrors the receipt
    /// thumbnail's flat-surface treatment but text-only — it's provenance, not
    /// an editable field, so it sits below the inputs as a quiet footnote.
    private func statementAttribution(_ statement: String) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "doc.text")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Tokens.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text("Imported from statement")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                Text(statement)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Imported from statement \(statement)")
    }

    // MARK: - Person / Event tags (#183)

    private var personField: some View {
        tagSelectorRow(
            label: "Person",
            icon: "person",
            placeholder: "Who was this for?",
            value: selectedPerson?.name,
            onTap: { showingPersonPicker = true },
            onClear: { selectedPerson = nil }
        )
    }

    private var eventField: some View {
        tagSelectorRow(
            label: "Event",
            icon: "calendar",
            placeholder: "Which occasion or trip?",
            value: selectedEvent?.name,
            onTap: { showingEventPicker = true },
            onClear: { selectedEvent = nil }
        )
    }

    // MARK: - Split shares (#188)

    /// A stepper for how many people the bill is split among, plus a live
    /// "Your share" readout so the user sees exactly what will be stored
    /// before saving. The amount field holds the receipt total; the stored
    /// expense is `total ÷ shares`. Sits below Person / Event because it's the
    /// same "who was this with" mental model — the split follows the people.
    private var sharesField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text("Split").eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "person.2")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Tokens.accentFinance)
                        .frame(width: 24)
                    Text(numberOfShares == 1 ? "Not split" : "Split \(numberOfShares) ways")
                        .font(.edBody)
                        .foregroundStyle(numberOfShares == 1 ? Tokens.inkSoft : Tokens.ink)
                    Spacer()
                    Stepper(
                        "",
                        value: $numberOfShares,
                        in: 1...50
                    )
                    .labelsHidden()
                    .tint(Tokens.accentFinance)
                }

                if numberOfShares > 1 {
                    shareReadout
                }
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(numberOfShares == 1 ? "Split: not split" : "Split \(numberOfShares) ways")
    }

    /// "Your share: CUR X of CUR Y" line shown only when the bill is split.
    /// Amounts are in the entered currency (pre-FX) so it reads back exactly
    /// what the user typed divided by the number of people.
    private var shareReadout: some View {
        let cur = currency.uppercased()
        return HStack(spacing: 4) {
            Text("Your share:")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
            Text("\(cur) \(formatShare(perShareValue))")
                .font(.edCaption)
                .monospacedDigit()
                .foregroundStyle(Tokens.ink)
            Text("of \(cur) \(formatShare(amountValue))")
                .font(.edCaption)
                .monospacedDigit()
                .foregroundStyle(Tokens.mutedSoft)
        }
    }

    private func formatShare(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// Shared "tappable field that opens a picker" row for Person / Event.
    /// Shows the selected name (or a placeholder), a chevron, and a clear
    /// button when a value is set.
    private func tagSelectorRow(
        label: String,
        icon: String,
        placeholder: String,
        value: String?,
        onTap: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text(label).eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            HStack(spacing: Space.sm) {
                Button(action: onTap) {
                    HStack(spacing: Space.sm) {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Tokens.accentFinance)
                            .frame(width: 24)
                        Text(value ?? placeholder)
                            .font(.edBody)
                            .foregroundStyle(value == nil ? Tokens.inkSoft : Tokens.ink)
                            .lineLimit(1)
                        Spacer()
                        if value == nil {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Tokens.muted)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if value != nil {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Tokens.mutedSoft)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear \(label.lowercased())")
                }
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value ?? "none")")
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        switch target {
        case .new:
            source = .manual
            // Focus the amount field shortly after the sheet finishes its
            // open animation. SwiftUI ignores focus changes made inside
            // .onAppear on a freshly presented sheet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                amountFocused = true
            }

        case .existing(let uuid):
            let descriptor = FetchDescriptor<LocalExpense>(
                predicate: #Predicate { $0.clientUUID == uuid }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                // Shares first: the stored `originalAmount` is the per-share
                // figure, so we reconstruct the RECEIPT TOTAL for the field
                // (share × shares) — consistent with what the user typed on
                // entry. Save() re-divides by shares to store the share again.
                numberOfShares = max(existing.numberOfShares, 1)
                amountText = formatAmountForEdit(existing.receiptTotalOriginal)
                currency = existing.originalCurrency
                category = existing.categoryEnum
                date = existing.date
                merchant = existing.merchant ?? ""
                descriptionField = existing.expenseDescription ?? ""
                paymentMethod = existing.paymentMethod ?? ""
                receiptImagePath = existing.receiptImagePath
                source = existing.sourceEnum
                statementLabel = existing.statementLabel
                if let uuid = existing.personUUID, let name = existing.personName?.trimmedNonEmpty {
                    selectedPerson = ExpenseTag(uuid: uuid, name: name)
                }
                if let uuid = existing.eventUUID, let name = existing.eventName?.trimmedNonEmpty {
                    selectedEvent = ExpenseTag(uuid: uuid, name: name)
                }
            }

        case .prefilled(let prefill):
            source = prefill.source
            receiptImagePath = prefill.receiptImagePath
            extractionBanner = prefill.extractionError
            extractionConfidence = prefill.confidence

            if let amount = prefill.amount {
                amountText = formatAmountForEdit(amount)
            }
            if let cur = prefill.currency, !cur.isEmpty {
                currency = cur.uppercased()
            }
            if let cat = prefill.category {
                category = cat
            }
            if let d = prefill.date {
                date = d
            }
            if let m = prefill.merchant {
                merchant = m
            }
            if let desc = prefill.descriptionText {
                descriptionField = desc
            }
            // For a successful extraction we don't auto-focus — the user is
            // reviewing fields, not typing from scratch. For a failure we
            // jump straight to the amount field after the sheet settles.
            if !prefill.extractionSucceeded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    amountFocused = true
                }
            }
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

        let store = SwiftDataStore.shared
        let fx = FXService(store: store)
        let service = ExpenseService(store: store)

        // The amount field holds the RECEIPT TOTAL; the user's SHARE is what
        // we store (#188). Divide first, then FX-convert the share so
        // `originalAmount` / `sgdAmount` are already the per-person figure and
        // every aggregation site stays correct without change. Equal split only.
        let shares = max(numberOfShares, 1)
        let shareAmount = amountValue / Double(shares)

        let conversion: (sgdAmount: Double, rate: Double)
        do {
            conversion = try await fx.convert(shareAmount, from: currency)
        } catch {
            errorMessage = "Couldn't convert \(currency) to SGD. Try again when online."
            return
        }

        do {
            switch target {
            case .new, .prefilled:
                let row = try service.addExpense(
                    date: date,
                    category: category,
                    merchant: merchant,
                    expenseDescription: descriptionField,
                    originalAmount: shareAmount,
                    originalCurrency: currency,
                    sgdAmount: conversion.sgdAmount,
                    fxRate: conversion.rate,
                    paymentMethod: paymentMethod,
                    source: source,
                    personUUID: selectedPerson?.uuid,
                    personName: selectedPerson?.name,
                    eventUUID: selectedEvent?.uuid,
                    eventName: selectedEvent?.name,
                    numberOfShares: shares
                )
                // ExpenseService.addExpense doesn't take receiptImagePath
                // (Phase A signature). Set it directly and save again — the
                // service does the same context.save() pattern.
                if let path = receiptImagePath {
                    row.receiptImagePath = path
                    try modelContext.save()
                }

            case .existing(let uuid):
                let descriptor = FetchDescriptor<LocalExpense>(
                    predicate: #Predicate { $0.clientUUID == uuid }
                )
                if let existing = try modelContext.fetch(descriptor).first {
                    try service.updateExpense(
                        existing,
                        date: date,
                        category: category,
                        merchant: merchant,
                        expenseDescription: descriptionField,
                        originalAmount: shareAmount,
                        originalCurrency: currency,
                        sgdAmount: conversion.sgdAmount,
                        fxRate: conversion.rate,
                        paymentMethod: paymentMethod,
                        person: .some(selectedPerson),
                        event: .some(selectedEvent),
                        numberOfShares: shares
                    )
                    // Persist receipt-path / source changes (e.g. user
                    // removed the image, or scan path → manual edit).
                    existing.receiptImagePath = receiptImagePath
                    existing.source = source.rawValue
                    try modelContext.save()
                }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Strip trailing zeros from the persisted amount so editing doesn't
    /// show "67.500000" on load.
    private func formatAmountForEdit(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private extension String {
    /// Trim whitespace, return nil for empty. Local copy of the same helper
    /// used elsewhere in Finance (kept file-private to avoid a public API).
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Person picker (#183)

/// Pick an existing person or create a new one inline. Selecting a person
/// dismisses; "New person" reveals an inline name field that find-or-creates
/// on Add. Case-insensitive reuse is handled by `PersonService.findOrCreate`.
struct PersonPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selection: ExpenseTag?

    @Query(sort: [SortDescriptor(\LocalPerson.name, order: .forward)])
    private var people: [LocalPerson]

    @State private var addingNew: Bool = false
    @State private var newName: String = ""
    @State private var errorMessage: String?

    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                List {
                    if addingNew {
                        newPersonRow
                    } else {
                        Button {
                            addingNew = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { nameFocused = true }
                        } label: {
                            Label("New person", systemImage: "plus.circle")
                                .foregroundStyle(Tokens.accentFinance)
                        }
                        .listRowBackground(Tokens.surface)
                    }

                    ForEach(people, id: \.clientUUID) { person in
                        Button {
                            selection = ExpenseTag(uuid: person.clientUUID, name: person.name)
                            dismiss()
                        } label: {
                            HStack(spacing: Space.sm) {
                                Circle()
                                    .fill(Color(personHex: person.colorHex))
                                    .frame(width: 12, height: 12)
                                Text(person.name)
                                    .foregroundStyle(Tokens.ink)
                                Spacer()
                                if selection?.uuid == person.clientUUID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Tokens.accentFinance)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Tokens.surface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Tokens.paper)
            }
            .navigationTitle("Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
            }
        }
    }

    private var newPersonRow: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            TextField("Name", text: $newName)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { commitNew() }
            if let errorMessage {
                Text(errorMessage)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.danger)
            }
            HStack {
                Button("Cancel") { addingNew = false; newName = ""; errorMessage = nil }
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .buttonStyle(.borderless)
                Spacer()
                Button("Add") { commitNew() }
                    .font(.edFootnote)
                    .foregroundStyle(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Tokens.muted : Tokens.accentFinance)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderless)
            }
        }
        .listRowBackground(Tokens.surface)
    }

    private func commitNew() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let person = try PersonService.default().findOrCreate(name: trimmed)
            selection = ExpenseTag(uuid: person.clientUUID, name: person.name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Event picker (#183)

/// Pick an existing event or create one inline (name + optional date range +
/// optional Trip link). Reuse is case-insensitive via
/// `EventService.findOrCreate`.
struct EventPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selection: ExpenseTag?

    @Query(sort: [SortDescriptor(\LocalEvent.updatedAt, order: .reverse)])
    private var events: [LocalEvent]

    @Query(sort: [SortDescriptor(\LocalTrip.startDate, order: .reverse)])
    private var trips: [LocalTrip]

    @State private var addingNew: Bool = false
    @State private var newName: String = ""
    @State private var useDates: Bool = false
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date()
    @State private var linkedTrip: LocalTrip?
    @State private var errorMessage: String?

    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                List {
                    if addingNew {
                        newEventSection
                    } else {
                        Button {
                            addingNew = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { nameFocused = true }
                        } label: {
                            Label("New event", systemImage: "plus.circle")
                                .foregroundStyle(Tokens.accentFinance)
                        }
                        .listRowBackground(Tokens.surface)
                    }

                    ForEach(events, id: \.clientUUID) { event in
                        Button {
                            selection = ExpenseTag(uuid: event.clientUUID, name: event.name)
                            dismiss()
                        } label: {
                            HStack(spacing: Space.sm) {
                                Image(systemName: "calendar")
                                    .foregroundStyle(Tokens.accentFinance)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.name)
                                        .foregroundStyle(Tokens.ink)
                                    if let subtitle = dateSubtitle(event) {
                                        Text(subtitle)
                                            .font(.edCaption)
                                            .foregroundStyle(Tokens.muted)
                                    }
                                }
                                Spacer()
                                if selection?.uuid == event.clientUUID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Tokens.accentFinance)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Tokens.surface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Tokens.paper)
            }
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
            }
        }
    }

    @ViewBuilder
    private var newEventSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            TextField("Event name", text: $newName)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { commitNew() }

            Toggle("Set dates", isOn: $useDates.animation())
                .font(.edFootnote)
                .tint(Tokens.accentFinance)

            if useDates {
                DatePicker("From", selection: $startDate, displayedComponents: .date)
                    .font(.edFootnote)
                    .tint(Tokens.accentFinance)
                DatePicker("To", selection: $endDate, in: startDate..., displayedComponents: .date)
                    .font(.edFootnote)
                    .tint(Tokens.accentFinance)
            }

            if !trips.isEmpty {
                Menu {
                    Button("None") { linkedTrip = nil }
                    ForEach(trips, id: \.clientUUID) { trip in
                        Button(trip.name) { linkedTrip = trip }
                    }
                } label: {
                    HStack {
                        Text("Link to trip")
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.inkSoft)
                        Spacer()
                        Text(linkedTrip?.name ?? "None")
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.ink)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Tokens.muted)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.danger)
            }

            HStack {
                Button("Cancel") { resetNew() }
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .buttonStyle(.borderless)
                Spacer()
                Button("Add") { commitNew() }
                    .font(.edFootnote)
                    .foregroundStyle(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Tokens.muted : Tokens.accentFinance)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderless)
            }
        }
        .listRowBackground(Tokens.surface)
    }

    private func dateSubtitle(_ event: LocalEvent) -> String? {
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM yyyy"
        if let start = event.startDate, let end = event.endDate {
            return "\(fmt.string(from: start)) – \(fmt.string(from: end))"
        }
        if let start = event.startDate {
            return fmt.string(from: start)
        }
        return nil
    }

    private func resetNew() {
        addingNew = false
        newName = ""
        useDates = false
        linkedTrip = nil
        errorMessage = nil
    }

    private func commitNew() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let event = try EventService.default().findOrCreate(
                name: trimmed,
                startDate: useDates ? startDate : nil,
                endDate: useDates ? endDate : nil,
                tripUUID: linkedTrip?.clientUUID
            )
            selection = ExpenseTag(uuid: event.clientUUID, name: event.name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Receipt rendering helpers

/// Small inline preview of a stored receipt. Renders the image for
/// `.jpg/.heic/.png` and a generic doc icon for `.pdf` (we don't need to
/// rasterise a PDF for a 64pt thumbnail — the icon is enough signal).
struct ReceiptThumbnailImage: View {
    let relativePath: String?

    var body: some View {
        Group {
            if let path = relativePath,
               let url = ReceiptStorage.shared.load(relativePath: path) {
                if isPDF(path) {
                    pdfPlaceholder
                } else if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    missingPlaceholder
                }
            } else {
                missingPlaceholder
            }
        }
        .background(Tokens.surface2)
    }

    private func isPDF(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".pdf")
    }

    private var pdfPlaceholder: some View {
        Image(systemName: "doc.text.fill")
            .font(.system(size: 26, weight: .regular))
            .foregroundStyle(Tokens.accentFinance)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingPlaceholder: some View {
        Image(systemName: "photo")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(Tokens.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-screen receipt viewer. Sheet presented from AddExpenseSheet when
/// the user taps the thumbnail.
///
/// Both branches are UIKit-backed for a native, smooth zoom that doesn't
/// fight the sheet's own gestures:
///  - Images: a `UIScrollView` + `UIImageView` with `viewForZooming`, so
///    pinch-to-zoom, drag-to-pan-while-zoomed, and double-tap-to-toggle
///    (fit ↔ 2.5×) all come from the platform. Fixed hand-rolled gesture
///    math would jank and clip; the scroll view gets it right for free.
///  - PDFs: a `PDFView` with `autoScales = true`, which gives native
///    pinch-zoom and page scrolling.
///
/// Branch is chosen by the receipt's file extension (.pdf ⇒ PDF viewer).
/// State resets on every present because the viewer is rebuilt each time
/// the sheet opens (the `UIViewRepresentable`s make fresh views).
struct ReceiptFullViewer: View {
    let relativePath: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let url = ReceiptStorage.shared.load(relativePath: relativePath) {
            if relativePath.lowercased().hasSuffix(".pdf") {
                PDFKitView(url: url)
                    .ignoresSafeArea(edges: .bottom)
            } else if let image = UIImage(contentsOfFile: url.path) {
                ZoomableImageView(image: image)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                unavailable
            }
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        Text("Receipt is no longer available.")
            .font(.edBody)
            .foregroundStyle(Tokens.muted)
    }
}

// MARK: - Zoomable image (UIScrollView-backed)

/// A `UIScrollView` wrapping a `UIImageView`, exposing native pinch-to-zoom,
/// pan-while-zoomed, and double-tap-to-toggle. `viewForZooming` is what makes
/// the scroll view drive the zoom; the image is centred in `layoutSubviews`
/// so it stays anchored while fit and while zoomed out.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> CenteringScrollView {
        let scrollView = CenteringScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bouncesZoom = true
        // Minimum is set to fit in `updateZoomScales`; start at 1.0.
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.imageView = imageView
        scrollView.addSubview(imageView)

        // Double-tap toggles between fit and a comfortable zoom.
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ uiView: CenteringScrollView, context: Context) {
        // No dynamic props to sync; the image is fixed for the viewer's life.
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? CenteringScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? CenteringScrollView)?.centerImage()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? CenteringScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                // Zoomed in → reset to fit.
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                // At fit → zoom toward the tapped point.
                let target = min(scrollView.minimumZoomScale * 2.5, scrollView.maximumZoomScale)
                let point = recognizer.location(in: scrollView.imageView)
                let size = scrollView.bounds.size
                let w = size.width / target
                let h = size.height / target
                let rect = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

/// A `UIScrollView` that keeps its single `imageView` sized to fit and
/// centred. The minimum zoom scale is the aspect-fit scale, so "fit" is the
/// true zoomed-out state and pinch-out never leaves dead space. Recomputes on
/// bounds changes (rotation, sheet resize).
private final class CenteringScrollView: UIScrollView {
    var imageView: UIImageView?
    private var lastBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        // Recompute fit only when the bounds actually change, so a zoom
        // (which triggers layout) doesn't clobber the user's current scale.
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            configureForFit()
        }
        centerImage()
    }

    /// Size the image view to the image's natural size, set the content size,
    /// and derive the aspect-fit scale as the minimum zoom (and initial zoom).
    private func configureForFit() {
        guard let imageView, let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        imageView.frame = CGRect(origin: .zero, size: imageSize)
        contentSize = imageSize

        let scaleW = bounds.width / imageSize.width
        let scaleH = bounds.height / imageSize.height
        let fitScale = min(scaleW, scaleH)

        minimumZoomScale = fitScale
        maximumZoomScale = max(fitScale * 5, fitScale)
        zoomScale = fitScale
    }

    /// Keep the image centred when it's smaller than the viewport (fit /
    /// zoomed-out), and pinned to the edges once it overflows (zoomed-in).
    func centerImage() {
        guard let imageView else { return }
        let boundsSize = bounds.size
        var frame = imageView.frame
        frame.origin.x = frame.width < boundsSize.width
            ? (boundsSize.width - frame.width) / 2
            : 0
        frame.origin.y = frame.height < boundsSize.height
            ? (boundsSize.height - frame.height) / 2
            : 0
        imageView.frame = frame
    }
}

// MARK: - PDF (PDFKit-backed)

/// A `PDFView` with `autoScales = true`, which gives native pinch-zoom,
/// page scrolling, and a fit-to-width initial layout. Loaded from the
/// on-disk receipt URL.
private struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .clear
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document == nil {
            uiView.document = PDFDocument(url: url)
        }
    }
}

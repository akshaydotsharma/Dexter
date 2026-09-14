import SwiftUI
import SwiftData

/// Rename a person in place (#530).
///
/// The person keeps their `clientUUID`, so every join that points at them — the
/// trip's participant list, an expense's person tag, `paidByPersonUUID`, every
/// split entry — survives untouched, and the settle-up balances do not move.
/// That is the whole reason this exists: before it, the only way to correct a
/// name was to remove the person and add a new one, which minted a new UUID and
/// left the old splits resolving to "Someone".
///
/// Reached from two places, because a person is met in two: the participant
/// chip inside the trip sheet, and the row in `PersonPickerSheet`. Both hand in
/// the record itself, so there is no second fetch and no id to get wrong.
struct RenamePersonSheet: View {
    @Environment(\.dismiss) private var dismiss

    let person: LocalPerson

    /// Called with the committed name after a successful save, so a caller
    /// holding its own copy of the name (a chip binding, a picked `ExpenseTag`)
    /// can refresh without waiting for a re-query.
    var onRenamed: ((String) -> Void)?

    @State private var name: String = ""
    @State private var errorMessage: String?

    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Name").eyebrow()
                    TextField("Name", text: $name)
                        .paperFieldOnMac()
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(commit)
                        .onChange(of: name) { _, _ in errorMessage = nil }
                        .padding(Space.md)
                        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                        .paperBorder(Tokens.border, radius: Radius.md)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.edCaption)
                            .foregroundStyle(Tokens.danger)
                    }

                    // Says plainly what the rename does NOT do. The worry this
                    // answers is the reason the feature was asked for.
                    // `Tokens.muted`, never `mutedSoft`: this is body text on
                    // `Tokens.paper` and the softer token fails AA in light mode.
                    Text("Their expenses, shares and balances stay exactly as they are.")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)

                    Spacer(minLength: 0)
                }
                .padding(Space.md)
            }
            .navigationTitle("Rename")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: commit)
                        .foregroundStyle(trimmed.isEmpty ? Tokens.muted : Tokens.accentFinance)
                        .disabled(trimmed.isEmpty)
                }
            }
            .onAppear {
                name = person.name
                // Tap lands the caret in the field, the same way every other
                // rename surface in the app behaves.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { nameFocused = true }
            }
        }
        // A macOS sheet sizes itself to its content and would otherwise collapse
        // to the height of its toolbar (#461).
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 220, idealHeight: 240)
        #endif
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        do {
            try PersonService.default().rename(person, to: trimmed)
            onRenamed?(trimmed)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

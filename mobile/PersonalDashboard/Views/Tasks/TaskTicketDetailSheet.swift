import SwiftUI

/// Detail surface for one task ticket (#399): the wallet card, the actions that
/// act on it, and an inline form for correcting whatever the extractor got wrong.
///
/// Mirrors `StayBookingDetailSheet` (#222) for the card-plus-actions shape. The
/// edit form is inline here rather than a separate editor because a ticket's
/// fields belong to the ticket, not to the task, so `TaskEditorSheet` has no
/// place to put them.
///
/// Editing being one tap from the card is what makes an imperfect extraction
/// acceptable: the model fills what it can read and the person fixes the rest.
struct TaskTicketDetailSheet: View {
    let ticket: TaskTicket
    let taskTitle: String
    /// Invoked after a save or a delete so the parent can reload its strip.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var showingScan = false
    @State private var showingOriginal = false
    @State private var isEditing = false
    @State private var showingDeleteConfirm = false
    @State private var errorMessage: String?

    // Draft fields, prefilled from the ticket on appear.
    @State private var eventTitle = ""
    @State private var hasEventDate = false
    @State private var eventDate = Date()
    @State private var startTimeText = ""
    @State private var venue = ""
    @State private var section = ""
    @State private var row = ""
    @State private var seat = ""
    @State private var gate = ""
    @State private var reference = ""

    private let service = TaskTicketService()

    private var accent: Color { Tokens.accent(for: .tasks) }

    /// Whether the bytes are on this device. Drives both the card's missing-file
    /// state and whether "View original" is offered at all.
    private var fileIsPresent: Bool {
        service.fileURL(for: ticket) != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: Space.lg) {
                        card
                        if isEditing {
                            editForm
                        } else {
                            actions
                        }
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.edCaption)
                                .foregroundStyle(Tokens.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(Space.lg)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Ticket")
            .inlineNavigationTitle()
            .toolbar {
                if isEditing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            prefill()
                            isEditing = false
                        }
                        .foregroundStyle(Tokens.muted)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .foregroundStyle(Tokens.ink)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(Tokens.ink)
                    }
                }
            }
            .onAppear(perform: prefill)
        }
        // The scan surface is a gate/turnstile idiom needing brightness and
        // idle-timer control; iOS-only, and `.fullScreenCover` is unavailable on
        // macOS regardless (issue #281).
        #if os(iOS)
        .fullScreenCover(isPresented: $showingScan) {
            TicketScanView(pass: ScannablePass(ticket: ticket, taskTitle: taskTitle))
        }
        #endif
        .sheet(isPresented: $showingOriginal) {
            TicketOriginalViewer(attachmentPath: ticket.attachmentPath)
        }
        .confirmationDialog(
            "Remove this ticket?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove ticket", role: .destructive) { delete() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The ticket file will be deleted from this device. The task itself stays.")
        }
    }

    // MARK: - Card

    @ViewBuilder
    private var card: some View {
        let cardView = TaskTicketCardView(
            ticket: ticket,
            taskTitle: taskTitle,
            fileIsPresent: fileIsPresent
        )

        #if os(iOS)
        // Tapping the card goes straight to the scanner: at a gate that is the
        // one action worth reaching for, so it should not be buried in a list.
        if ticket.hasBarcode {
            Button {
                Haptics.light()
                showingScan = true
            } label: {
                cardView
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Present this ticket to scan")
        } else {
            cardView
        }
        #else
        cardView
        #endif
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: Space.sm) {
            #if os(iOS)
            if ticket.hasBarcode {
                actionRow(icon: "barcode.viewfinder", title: "Scan ticket") {
                    Haptics.light()
                    showingScan = true
                }
            }
            #endif
            if fileIsPresent {
                actionRow(icon: "doc.text.magnifyingglass", title: "View original ticket") {
                    Haptics.light()
                    showingOriginal = true
                }
            }
            actionRow(icon: "pencil", title: "Edit details") {
                Haptics.light()
                isEditing = true
            }
            actionRow(icon: "trash", title: "Remove ticket", isDestructive: true) {
                showingDeleteConfirm = true
            }
        }
    }

    private func actionRow(
        icon: String,
        title: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isDestructive ? Tokens.danger : accent)
                    .frame(width: 24)
                Text(title)
                    .font(.edBodyMedium)
                    .foregroundStyle(isDestructive ? Tokens.danger : Tokens.ink)
                Spacer(minLength: 0)
                if !isDestructive {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokens.mutedSoft)
                }
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - Edit form

    private var editForm: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            labeled("Event") {
                field($eventTitle, placeholder: "What is this ticket for?")
            }
            labeled("Date") {
                VStack(spacing: 0) {
                    HStack {
                        Text("Set a date")
                            .font(.edBody)
                            .foregroundStyle(Tokens.inkSoft)
                        Spacer()
                        Toggle("", isOn: $hasEventDate.animation())
                            .labelsHidden()
                            .tint(accent)
                    }
                    .padding(Space.md)

                    if hasEventDate {
                        Divider().background(Tokens.divider)
                        HStack {
                            // Date only. The time is a free-text field below, kept
                            // verbatim as printed — see `LocalTaskTicket` on why a
                            // single absolute Date is the wrong shape here.
                            DatePicker("", selection: $eventDate, displayedComponents: [.date])
                                .paperDatePickerOnMac()
                                .labelsHidden()
                                .tint(accent)
                            Spacer(minLength: 0)
                        }
                        .padding(Space.md)
                    }
                }
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
            }
            labeled("Time as printed") {
                field($startTimeText, placeholder: "e.g. 20:00 or Doors 19:00")
            }
            labeled("Venue") {
                field($venue, placeholder: "Where is it?")
            }
            HStack(spacing: Space.md) {
                labeled("Section") { field($section, placeholder: "Section") }
                labeled("Row") { field($row, placeholder: "Row") }
            }
            HStack(spacing: Space.md) {
                labeled("Seat") { field($seat, placeholder: "Seat") }
                labeled("Gate") { field($gate, placeholder: "Gate") }
            }
            labeled("Reference") {
                field($reference, placeholder: "Booking or order reference")
            }
        }
    }

    private func labeled<Content: View>(
        _ label: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text(label).eyebrow()
            content()
        }
    }

    private func field(_ text: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: text)
            .paperFieldOnMac()
            .font(.edBody)
            .foregroundStyle(Tokens.ink)
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
    }

    // MARK: - Actions

    private func prefill() {
        eventTitle = ticket.eventTitle
        hasEventDate = ticket.eventDate != nil
        eventDate = ticket.eventDate ?? Date()
        startTimeText = ticket.startTimeText
        venue = ticket.venue
        seat = ticket.seat
        gate = ticket.gate
        reference = ticket.reference
        let meta = ticket.ticketMeta
        section = meta?.section ?? ""
        row = meta?.row ?? ""

        // A ticket the extractor could not read opens straight into the form,
        // because a card that is blank apart from a barcode has nothing to look
        // at and everything to fill in.
        if ticket.isBare { isEditing = true }
    }

    private func save() {
        // Preserve any extras we don't surface (eventType) rather than dropping
        // them on save.
        var meta = ticket.ticketMeta ?? TicketMeta()
        meta.section = trimmedOrNil(section)
        meta.row = trimmedOrNil(row)

        do {
            _ = try service.update(
                id: ticket.id,
                eventTitle: eventTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                eventDate: .some(hasEventDate ? Calendar.current.startOfDay(for: eventDate) : nil),
                startTimeText: startTimeText.trimmingCharacters(in: .whitespacesAndNewlines),
                venue: venue.trimmingCharacters(in: .whitespacesAndNewlines),
                seat: seat.trimmingCharacters(in: .whitespacesAndNewlines),
                gate: gate.trimmingCharacters(in: .whitespacesAndNewlines),
                reference: reference.trimmingCharacters(in: .whitespacesAndNewlines),
                meta: meta
            )
            errorMessage = nil
            isEditing = false
            onChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        do {
            try service.delete(ticket)
            onChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func trimmedOrNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

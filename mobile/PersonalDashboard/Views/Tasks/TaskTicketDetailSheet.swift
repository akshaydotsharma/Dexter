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
    let ownerTitle: String
    /// Invoked after a save or a delete so the parent can reload its strip.
    let onChange: () -> Void
    /// Applies the edit instead of writing it through the service. Set for a ticket
    /// attached to a task that has not been saved yet: there is no row to update, so
    /// the edited copy goes back to whoever is holding it.
    var onSave: ((TaskTicket) -> Void)? = nil
    /// Removes the ticket instead of soft-deleting a row, for the same reason.
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var showingOriginal = false
    #if os(iOS)
    @State private var showingApplePass = false
    #endif
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
    @State private var eventURL = ""

    /// Wallet membership as it stands right now: the stored override when there is
    /// one, otherwise whatever the automatic rule decides. Kept outside the edit
    /// form because it applies immediately rather than on Save, the way a switch
    /// that moves something between two places should.
    @State private var showInWallet = false

    /// The override this sheet has written, if any. Held separately because
    /// `ticket` is the copy captured when the sheet was presented and never sees
    /// the write: without this, editing a field afterwards would save a `TicketMeta`
    /// rebuilt from that stale copy and silently undo the flip.
    @State private var walletOverride: Bool?

    @Environment(\.openURL) private var openURL

    private let service = TaskTicketService()

    private var accent: Color { Tokens.accent(for: ticket.owner.section) }

    /// Whether the bytes are on this device. Drives both the card's missing-file
    /// state and whether "View original" is offered at all.
    private var fileIsPresent: Bool {
        service.fileURL(for: ticket) != nil
    }

    #if os(iOS)
    /// The stored `.pkpass` bytes, when the attachment is one (#420). Read on each
    /// evaluation rather than cached: it is one small file and it cannot go stale.
    private var storedPassData: Data? {
        guard TicketStorage.isPass(ticket.attachmentPath),
              let url = service.fileURL(for: ticket) else { return nil }
        return try? Data(contentsOf: url)
    }
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: Space.lg) {
                        filePreview
                        details
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
            .navigationTitle("Attachment")
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
        // Apple Wallet is where you look at a `.pkpass`, and PassKit is iOS-only.
        #if os(iOS)
        .sheet(isPresented: $showingApplePass) {
            if let passData = storedPassData {
                AddPassToAppleWallet(data: passData) { showingApplePass = false }
                    .ignoresSafeArea()
            }
        }
        #endif
        .sheet(isPresented: $showingOriginal) {
            TicketOriginalViewer(attachmentPath: ticket.attachmentPath)
        }
        .confirmationDialog(
            "Remove this attachment?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove attachment", role: .destructive) { delete() }
            Button("Keep it", role: .cancel) {}
        } message: {
            // A pending ticket has no task behind it yet, so promising that the task
            // stays would be describing something that does not exist.
            Text(
                onDelete == nil
                    ? "The file will be deleted from this device. The \(ticket.owner.noun) itself stays."
                    : "The file will be deleted from this device."
            )
        }
    }

    /// One label-over-value field. Blank and whitespace-only values collapse to an
    /// empty string at init, so the panel never renders a labelled blank.
    struct TicketDetailField: Identifiable {
        let id = UUID()
        let label: String
        let value: String

        init(label: String, value: String?) {
            self.label = label
            self.value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    // MARK: - The file, and what was read off it

    /// A preview of the stored file, big enough to recognise it by.
    ///
    /// This replaces the wallet-style card face this sheet used to lead with
    /// (#466). A pass belongs on the shelf built for passes, and every document
    /// that reached this sheet got the pass treatment whether or not it was one.
    /// What is useful here is the file itself and everything read off it.
    @ViewBuilder
    private var filePreview: some View {
        // A `.pkpass` has no page to render, so its preview is an icon and there
        // is nothing for a tap to open. Same predicate as the "View original
        // file" row below, so the two can never disagree about what is viewable.
        let canOpen = fileIsPresent && !TicketStorage.isPass(ticket.attachmentPath)

        if fileIsPresent {
            let preview = TicketAttachmentThumbnail(
                relativePath: ticket.attachmentPath,
                accent: accent
            )
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)

            if canOpen {
                Button {
                    Haptics.light()
                    showingOriginal = true
                } label: {
                    preview
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View the original file")
            } else {
                preview
            }
        } else {
            missingFileNote
        }
    }

    /// Shown when the row synced across from another device but its bytes did
    /// not. Being explicit about this beats an empty frame that reads as a bug:
    /// the file is not lost, it is just elsewhere.
    private var missingFileNote: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Tokens.mutedSoft)
            Text("The file is on your other device")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    /// Everything the extractor read, as plain labelled fields.
    ///
    /// The card face this replaces showed the first three facts and left the rest
    /// to "the detail sheet" — which is here, so here they all are. A scrolling
    /// sheet has none of the width pressure that capped that row at three.
    @ViewBuilder
    private var details: some View {
        let fields = detailFields
        if !fields.isEmpty || ticket.hasBarcode {
            VStack(alignment: .leading, spacing: Space.md) {
                Text(ticket.displayTitle(fallback: ownerTitle))
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.label.uppercased())
                            .font(.edEyebrow)
                            .tracking(1.0)
                            .foregroundStyle(Tokens.muted)
                        Text(field.value)
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if ticket.hasBarcode { barcodeField }
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    /// The document's own barcode, rendered as one more field rather than as a
    /// tear-off stub.
    ///
    /// Load-bearing on macOS, which has no present-to-scan surface at all: without
    /// it, a `.pkpass` or a PDF whose preview is an icon would leave a Mac user no
    /// way to see the code the file carries.
    private var barcodeField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BARCODE")
                .font(.edEyebrow)
                .tracking(1.0)
                .foregroundStyle(Tokens.muted)
            BarcodeImageView(
                payload: ticket.barcodePayload,
                symbology: ticket.barcodeSymbology,
                attachmentPath: ticket.attachmentPath,
                height: 62,
                compact: true,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.sm)
            .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The ordering the card face used, minus its three-slot cap, with the date,
    /// time and location it carried in its header and secondary slots folded in
    /// at the front.
    ///
    /// `startTimeText` is never reformatted: it is what the document printed.
    private var detailFields: [TicketDetailField] {
        let meta = ticket.ticketMeta
        var out: [TicketDetailField] = [
            TicketDetailField(
                label: "Date",
                value: ticket.eventDate.map {
                    $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
                }
            ),
            TicketDetailField(label: "Time", value: ticket.startTimeText),
            TicketDetailField(label: "Location", value: ticket.venue),
            TicketDetailField(label: "Seat", value: ticket.seat),
            TicketDetailField(label: "Section", value: meta?.section),
            TicketDetailField(label: "Row", value: meta?.row),
            TicketDetailField(label: "Gate", value: ticket.gate),
            TicketDetailField(label: "Guest", value: meta?.guestName)
        ]
        // Whatever else the document printed, under its own labels (#420).
        out.append(contentsOf: (meta?.faceFields ?? []).map {
            TicketDetailField(label: $0.label, value: $0.value)
        })
        // Back fields are the ones Wallet puts behind the pass: the full address,
        // the ticket type, the guest email.
        out.append(contentsOf: (meta?.backFields ?? []).map {
            TicketDetailField(label: $0.label, value: $0.value)
        })
        out.append(TicketDetailField(label: "Ref", value: ticket.reference))
        return out.filter { !$0.value.isEmpty }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: Space.sm) {
            // No "Scan ticket" row (#466). Presenting a pass at a gate is what the
            // Wallet is for, and a document that earns a card is already on that
            // shelf. One that does not carries a barcode nobody scans at a door — a
            // rental company's manage-my-booking QR, say — and it stays visible as
            // a field above rather than being dressed up as a credential here.
            //
            // A `.pkpass` is a signed data bundle with no page to render, so the viewer
            // would show its "unavailable" state on an intact file (#420). Apple Wallet
            // is where you look at a pass, and it is iOS-only.
            #if os(iOS)
            if fileIsPresent, let passData = storedPassData,
               AddPassToAppleWallet.pass(from: passData) != nil {
                actionRow(icon: "wallet.pass", title: "Show in Apple Wallet") {
                    Haptics.light()
                    showingApplePass = true
                }
            } else if fileIsPresent, !TicketStorage.isPass(ticket.attachmentPath) {
                actionRow(icon: "doc.text.magnifyingglass", title: "View original file") {
                    Haptics.light()
                    showingOriginal = true
                }
            }
            #else
            if fileIsPresent, !TicketStorage.isPass(ticket.attachmentPath) {
                actionRow(icon: "doc.text.magnifyingglass", title: "View original file") {
                    Haptics.light()
                    showingOriginal = true
                }
            }
            #endif
            // The event's own page (#412). Apple Wallet puts this on the back of a
            // pass rather than its face, which is the right place: it is what you
            // open before the event, not what you hold up at the door.
            if let url = resolvedEventURL {
                actionRow(icon: "safari", title: "Open event page") {
                    Haptics.light()
                    openURL(url)
                }
            }
            walletRow
            actionRow(icon: "pencil", title: "Edit details") {
                Haptics.light()
                isEditing = true
            }
            actionRow(icon: "trash", title: "Remove attachment", isDestructive: true) {
                showingDeleteConfirm = true
            }
        }
    }

    /// The one control here that is not an action: whether this attachment shows up
    /// in the Wallet (#414).
    ///
    /// The rule that decides it by default reads a model's judgement of a document
    /// it saw once, and it gets things wrong in both directions. Before this, the
    /// only way to correct it was removing the attachment, which deletes the file to
    /// fix a display decision. It sits above Edit rather than inside the form
    /// because it takes effect on the flip, not on Save.
    private var walletRow: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "wallet.pass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Show in Wallet")
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                Text(showInWallet ? "Kept with your passes" : "Stays on the \(ticket.owner.noun) only")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
            }
            Spacer(minLength: 0)
            // A hand-written binding rather than `$showInWallet` plus `onChange`:
            // `prefill` assigns the state directly on every appear and on Cancel,
            // and an `onChange` would read those as flips and stamp an override on
            // a sheet nobody touched.
            Toggle("", isOn: Binding(
                get: { showInWallet },
                set: { isOn in
                    showInWallet = isOn
                    setWalletMembership(isOn)
                }
            ))
            .labelsHidden()
            .tint(accent)
        }
        .padding(Space.md)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Show in Wallet")
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
            labeled("Event page") {
                field($eventURL, placeholder: "Link to the event")
                    .noAutocapitalization()
                    .autocorrectionDisabled(true)
                    .urlKeyboard()
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
        eventURL = meta?.eventURL ?? ""
        showInWallet = walletOverride ?? ticket.belongsInWallet

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
        meta.eventURL = trimmedOrNil(eventURL)
        if let walletOverride { meta.showInWallet = walletOverride }

        let day = hasEventDate ? Calendar.current.startOfDay(for: eventDate) : nil

        // A ticket held unsaved in the editor has no row yet, so the edit goes back
        // to its holder instead of to the store.
        if let onSave {
            var edited = ticket
            edited.eventTitle = eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            edited.eventDate = day
            edited.startTimeText = startTimeText.trimmingCharacters(in: .whitespacesAndNewlines)
            edited.venue = venue.trimmingCharacters(in: .whitespacesAndNewlines)
            edited.seat = seat.trimmingCharacters(in: .whitespacesAndNewlines)
            edited.gate = gate.trimmingCharacters(in: .whitespacesAndNewlines)
            edited.reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            edited.ticketMetaJSON = meta.isEmpty ? "" : meta.encodedString()
            onSave(edited)
            errorMessage = nil
            isEditing = false
            dismiss()
            return
        }

        do {
            _ = try service.update(
                id: ticket.id,
                eventTitle: eventTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                eventDate: .some(day),
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

    /// Write the person's Wallet answer, on the flip rather than on Save.
    ///
    /// Always stores an explicit value, even when it agrees with what the rule
    /// already decided: a switch that silently reverts because the extractor's
    /// judgement changed underneath it is worse than one that stays where it was
    /// put. Nothing dismisses here — this is a setting on the sheet, not an
    /// errand you leave to run.
    private func setWalletMembership(_ isOn: Bool) {
        walletOverride = isOn
        var meta = ticket.ticketMeta ?? TicketMeta()
        meta.showInWallet = isOn

        // A ticket still held unsaved in the task editor has no row to update, so
        // the flip rides along on the copy its holder is keeping.
        if let onSave {
            var edited = ticket
            edited.ticketMetaJSON = meta.encodedString()
            onSave(edited)
            return
        }

        do {
            _ = try service.update(id: ticket.id, meta: meta)
            errorMessage = nil
            onChange()
        } catch {
            errorMessage = error.localizedDescription
            // Put the switch back where it was: the store did not move, so neither
            // should the control claiming to reflect it.
            walletOverride = nil
            showInWallet = ticket.belongsInWallet
        }
    }

    private func delete() {
        if let onDelete {
            onDelete()
            dismiss()
            return
        }
        do {
            try service.delete(ticket)
            onChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The stored event page as a URL, coercing a bare host to https so a value typed
    /// by hand still opens. Nil when there is nothing usable, which is what hides the
    /// action rather than offering one that goes nowhere.
    private var resolvedEventURL: URL? {
        guard let raw = ticket.ticketMeta?.eventURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(string: "https://\(raw)")
    }

    private func trimmedOrNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

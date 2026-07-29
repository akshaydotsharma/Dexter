import SwiftUI
import SwiftData

/// The Wallet: one place holding every scannable card, whatever created it
/// (#398).
///
/// Three things it does, in order of how often they matter:
///  1. **Shows** every card as the full wallet-style `TicketCardView`, one after
///     the other, grouped into Upcoming and Past. Upcoming runs soonest-first so
///     the card you are about to scan is at the top; Past runs most-recent-first.
///  2. **Presents to scan** on tap: straight into `TicketScanView` (max
///     brightness, idle timer held) on iPhone, which is the whole point of a
///     wallet at a gate. A card with nothing scannable opens its detail sheet
///     instead of a screen with an empty barcode panel.
///  3. **Adds** a card with no trip involved: camera, Photos, PDF, or by hand.
///     Uploads run the #222 pipeline (persist → decode barcode → BCBP parse →
///     one Claude call) via `TicketExtraction.runForWallet`.
///
/// The list is a VIEW over existing data (see `WalletEntry`), so a trip's
/// boarding pass appears here and on the trip timeline with one record behind
/// both. Cards it does not own are read-only here and route back to the surface
/// that does own them.
struct WalletView: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var router: AppRouter

    @Query(sort: \LocalWalletCard.dayDate, order: .reverse)
    private var cards: [LocalWalletCard]

    /// Every itinerary item, filtered down to the ticketed ones in
    /// `WalletEntry.build`. `hasTicket` is computed (it reads two string
    /// properties), so it cannot be expressed as a `#Predicate` and the filter
    /// has to happen in memory. Personal scale, so a full fetch is fine — the
    /// same call the trip timeline already makes per trip.
    @Query private var itineraryItems: [LocalItineraryItem]

    /// Only used to label a borrowed card with its trip name.
    @Query private var trips: [LocalTrip]

    // MARK: Add / edit state

    @State private var editorTarget: WalletCardEditorTarget?
    @State private var detailTarget: WalletDetailTarget?

    /// Blocks the FAB and shows the "Reading ticket…" overlay while an upload is
    /// being persisted, decoded and extracted. Mirrors `TripDetailView`.
    @State private var isProcessingTicket = false
    @State private var ticketError: String?

    @State private var showingCamera = false
    @State private var showingPhotoLibrary = false
    @State private var showingPDFPicker = false

    /// Card queued for deletion, driving the confirmation dialog. Holds the UUID
    /// rather than the model so a re-render can't hand the dialog a deleted row.
    @State private var pendingDeleteID: UUID?

    #if os(iOS)
    /// Full-screen present-to-scan target (iOS only — the surface depends on
    /// `UIScreen.brightness` and the idle timer).
    @State private var scanTarget: WalletScanTarget?
    #endif

    private var entries: [WalletEntry] {
        WalletEntry.build(cards: cards, itineraryItems: itineraryItems, trips: trips)
    }

    private var groups: WalletGroups {
        WalletEntry.grouped(entries, today: Calendar.current.startOfDay(for: .now))
    }

    var body: some View {
        ZStack {
            Tokens.paper.canvasIgnoresSafeArea()

            VStack(spacing: 0) {
                // iOS in-view top bar; macOS uses the native window toolbar.
                #if os(iOS)
                TopBar(
                    title: "Wallet",
                    onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } }
                )
                #endif
                content
                    .macSectionChrome("Wallet")
                    #if os(macOS)
                    .focusedSceneValue(\.newItemAction, NewItemAction(title: "New Card") {
                        editorTarget = .new
                    })
                    #endif
            }

            addMenu

            if isProcessingTicket {
                processingOverlay
            }
        }
        .activeSection(.wallet)
        .sheet(item: $editorTarget) { target in
            WalletCardEditorSheet(target: target)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // Card detail: the tinted card plus its actions. iOS presents it
        // full-screen to match TicketScanView; macOS has no `.fullScreenCover`,
        // so it presents the same view as a sheet (same treatment as
        // `StayBookingDetailSheet`, issue #281).
        #if os(iOS)
        .fullScreenCover(item: $detailTarget) { target in
            detailSheet(for: target)
        }
        .fullScreenCover(item: $scanTarget) { target in
            TicketScanView(pass: ScannablePass(card: target.card))
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { data in
                showingCamera = false
                handleTicketData(data, isPDF: false)
            }
            .ignoresSafeArea()
        }
        #else
        .sheet(item: $detailTarget) { target in
            detailSheet(for: target)
        }
        #endif
        .photoLibraryPicker(isPresented: $showingPhotoLibrary) { data in
            handleTicketData(data, isPDF: false)
        }
        .pdfPicker(isPresented: $showingPDFPicker) { data, _ in
            handleTicketData(data, isPDF: true)
        }
        .confirmationDialog(
            "Delete this card?",
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteID { delete(cardID: id) }
                pendingDeleteID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text("The card and its stored ticket file are removed from this device.")
        }
        .alert(
            "Couldn't save the ticket",
            isPresented: Binding(
                get: { ticketError != nil },
                set: { if !$0 { ticketError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { ticketError = nil }
        } message: {
            Text(ticketError ?? "")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let grouped = groups
        if grouped.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: Space.lg) {
                    cardGroup(
                        title: "Upcoming",
                        entries: grouped.upcoming,
                        accent: Tokens.accent(for: .wallet),
                        soft: Tokens.paper2,
                        isPast: false
                    )
                    cardGroup(
                        title: "Past",
                        entries: grouped.past,
                        accent: Tokens.muted,
                        soft: Tokens.paper2,
                        isPast: true
                    )

                    // Bumper so the last card clears the floating tab bar + FAB.
                    Color.clear.frame(height: 96)
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.sm)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder
    private func cardGroup(
        title: String,
        entries: [WalletEntry],
        accent: Color,
        soft: Color,
        isPast: Bool
    ) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: Space.md) {
                groupHeader(title: title, count: entries.count, accent: accent, soft: soft)

                ForEach(entries) { entry in
                    // Edit / delete are handed over only for a card the wallet
                    // owns, open-source only for a borrowed one. The row renders
                    // whichever closures it was given and needs no knowledge of
                    // the source kinds.
                    let ownID = walletCardID(of: entry)
                    WalletCardRow(
                        entry: entry,
                        isPast: isPast,
                        onTap: { open(entry) },
                        onEdit: ownID.map { id in { editorTarget = .existing(id) } },
                        onDelete: ownID.map { id in { pendingDeleteID = id } },
                        onOpenSource: ownID == nil ? { openSource(of: entry) } : nil
                    )
                }
            }
        }
    }

    /// Same shape as the Trips / Tasks section headers: accent title plus a
    /// count capsule, left-aligned on paper.
    private func groupHeader(title: String, count: Int, accent: Color, soft: Color) -> some View {
        HStack(spacing: Space.sm) {
            Text(title)
                .font(.edHeading)
                .foregroundStyle(accent)
            Text("\(count)")
                .font(.edCaption)
                .foregroundStyle(accent)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 2)
                .background(soft, in: Capsule())
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Spacer()
            Image(systemName: "wallet.pass")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Tokens.muted)
            Text("Nothing to scan yet")
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.center)
            Text("Add a boarding pass, an event ticket, or any pass with a barcode. Photograph it or drop in the PDF and the details are read for you. Tickets already attached to a trip show up here on their own.")
                .font(.edSubheadline)
                .foregroundStyle(Tokens.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xl)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Space.lg)
    }

    // MARK: - Add menu (FAB)

    private var addMenu: some View {
        Menu {
            // Camera capture is iOS-only (UIImagePickerController +
            // `.fullScreenCover`), matching the trip ticket menu.
            #if os(iOS)
            Button {
                Haptics.light()
                showingCamera = true
            } label: {
                Label("Scan a ticket", systemImage: "camera")
            }
            #endif
            Button {
                showingPhotoLibrary = true
            } label: {
                Label("Ticket from Photos", systemImage: "photo")
            }
            Button {
                showingPDFPicker = true
            } label: {
                Label("Ticket from PDF", systemImage: "doc.text")
            }
            Divider()
            Button {
                editorTarget = .new
            } label: {
                Label("Add manually", systemImage: "square.and.pencil")
            }
        } label: {
            fabCircle
        }
        .disabled(isProcessingTicket)
        .padding(.trailing, 22)
        .padding(.bottom, BottomTabBarMetrics.fabBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .accessibilityLabel("Add a card")
    }

    /// Same circular FAB the trip timeline uses, in the wallet's accent.
    private var fabCircle: some View {
        Image(systemName: "plus")
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(Tokens.accentFg)
            .frame(width: 48, height: 48)
            .background(Tokens.accent(for: .wallet), in: Circle())
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
    }

    private var processingOverlay: some View {
        ZStack {
            Tokens.paper.opacity(0.72).ignoresSafeArea()
            VStack(spacing: Space.md) {
                ProgressView()
                Text("Reading ticket…")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.inkSoft)
            }
            .padding(Space.xl)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.lg)
        }
        .transition(.opacity)
    }

    // MARK: - Detail

    @ViewBuilder
    private func detailSheet(for target: WalletDetailTarget) -> some View {
        WalletCardDetailSheet(
            entry: target.entry,
            onEdit: walletCardID(of: target.entry).map { id in
                {
                    detailTarget = nil
                    editorTarget = .existing(id)
                }
            },
            onOpenSource: target.entry.source.isEditableInWallet
                ? nil
                : {
                    let entry = target.entry
                    detailTarget = nil
                    openSource(of: entry)
                }
        )
    }

    // MARK: - Actions

    /// Tapping a card goes straight to the thing you tapped it for: the big
    /// high-contrast barcode. A card with nothing scannable (a manually typed
    /// confirmation code) would show an empty barcode panel, so it opens the
    /// detail surface instead. macOS has no scan surface at all and always shows
    /// the detail.
    private func open(_ entry: WalletEntry) {
        Haptics.light()
        #if os(iOS)
        if entry.card.hasTicket {
            scanTarget = WalletScanTarget(id: entry.id, card: entry.card)
        } else {
            detailTarget = WalletDetailTarget(entry: entry)
        }
        #else
        detailTarget = WalletDetailTarget(entry: entry)
        #endif
    }

    /// Jump to the surface that owns a borrowed card. Uses the same
    /// `router.focus` deep-link the Activity timeline uses, so the trip opens on
    /// its detail rather than the trip list.
    private func openSource(of entry: WalletEntry) {
        switch entry.source {
        case .wallet:
            break
        case .trip(_, let tripID, _):
            router.focus = ActivityFocus(section: .itineraries, id: tripID)
            router.go(to: .itineraries)
        }
    }

    /// The `LocalWalletCard.clientUUID` behind an entry, or `nil` for a borrowed
    /// card that has no wallet row of its own.
    private func walletCardID(of entry: WalletEntry) -> UUID? {
        switch entry.source {
        case .wallet(let cardID): return cardID
        case .trip:               return nil
        }
    }

    // MARK: - Upload

    private func handleTicketData(_ data: Data?, isPDF: Bool) {
        guard let data else { return }
        Task { await processTicket(data: data, isPDF: isPDF) }
    }

    /// Run the upload through the shared ticket pipeline and open the card it
    /// created. A degraded extraction still produced a card (the file is never
    /// lost), so it opens the editor to be filled in rather than showing an
    /// error.
    private func processTicket(data: Data, isPDF: Bool) async {
        withAnimation(.easeInOut(duration: 0.15)) { isProcessingTicket = true }
        defer { withAnimation(.easeInOut(duration: 0.15)) { isProcessingTicket = false } }

        do {
            let result = try await TicketExtraction().runForWallet(
                data: data,
                isPDF: isPDF,
                context: modelContext
            )
            Haptics.light()
            if result.degraded {
                editorTarget = .existing(result.itemUUID)
            } else if let card = fetchCard(result.itemUUID) {
                // Straight to the card that was just added, so the upload ends
                // on something the user can see and scan.
                //
                // Fetched from the context rather than read off `cards`: the
                // `@Query` has not necessarily republished in the same run-loop
                // turn as the insert, so reading it here can miss the brand new
                // row and silently skip this step.
                if let entry = WalletEntry.build(cards: [card], itineraryItems: [], trips: []).first {
                    open(entry)
                }
            }
        } catch {
            ticketError = (error as? LocalizedError)?.errorDescription
                ?? "We couldn't save that ticket. Please try again."
        }
    }

    /// Read one card straight from the store, bypassing the `@Query` snapshot.
    private func fetchCard(_ id: UUID) -> LocalWalletCard? {
        let descriptor = FetchDescriptor<LocalWalletCard>(
            predicate: #Predicate { $0.clientUUID == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// Delete a standalone card and its stored file. The file goes first: a
    /// failed row delete would otherwise leave an orphan the user can never
    /// reach, whereas a deleted file with a surviving row degrades to a card
    /// that reports no ticket.
    private func delete(cardID: UUID) {
        guard let card = fetchCard(cardID) else { return }
        if !card.attachmentPath.isEmpty {
            try? TicketStorage.shared.delete(relativePath: card.attachmentPath)
        }
        modelContext.delete(card)
        try? modelContext.save()
        Haptics.destructive()
    }
}

// MARK: - Presentation targets

/// `.sheet(item:)` payload for the card detail surface.
struct WalletDetailTarget: Identifiable {
    let entry: WalletEntry
    var id: String { entry.id }
}

#if os(iOS)
/// `.fullScreenCover(item:)` payload for present-to-scan. Carries the projected
/// card rather than a model id: the scan surface is display-only, and passing the
/// value means it cannot be handed a row that has since been deleted.
struct WalletScanTarget: Identifiable {
    let id: String
    let card: TicketCardData
}
#endif

// MARK: - Row

/// One card in the wallet list: a provenance chip, the card itself, and the
/// gestures that act on it.
private struct WalletCardRow: View {
    let entry: WalletEntry
    let isPast: Bool
    let onTap: () -> Void
    /// `nil` for a borrowed card, which the wallet does not edit.
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    /// `nil` for a card the wallet owns; set for a borrowed one.
    let onOpenSource: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            sourceChip
            TicketCardView(item: entry.card, timeText: entry.timeText)
        }
        // Past cards recede rather than disappear: still legible (you may need
        // last week's receipt) but clearly not the one to scan today.
        .opacity(isPast ? 0.7 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            if let onEdit {
                Button {
                    onEdit()
                } label: {
                    Label("Edit details", systemImage: "pencil")
                }
            }
            if let onOpenSource {
                Button {
                    onOpenSource()
                } label: {
                    Label("Open \(entry.source.label)", systemImage: "arrow.up.forward.app")
                }
            }
            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete card", systemImage: "trash")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.card.title), \(entry.source.label)")
        .accessibilityHint(entry.card.hasTicket ? "Opens the barcode to scan" : "Opens the card details")
    }

    /// Provenance line: where the card came from, plus its date. Small and
    /// quiet — the card below it is the object, this is the label on the sleeve.
    private var sourceChip: some View {
        HStack(spacing: 5) {
            Image(systemName: entry.source.icon)
                .font(.system(size: 10, weight: .medium))
            Text(entry.source.label)
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.2)
                .lineLimit(1)
            Text("·")
                .font(.edEyebrow)
            Text(dayLabel)
                .font(.edEyebrow)
                .tracking(1.0)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Tokens.muted)
        .padding(.leading, 2)
    }

    /// "MON 14 JUL" style, with the year appended once the card falls outside
    /// this one, so an old pass never reads as this year's.
    private var dayLabel: String {
        let day = entry.day
        let sameYear = Calendar.current.component(.year, from: day)
            == Calendar.current.component(.year, from: Date())
        let style = Date.FormatStyle.dateTime
            .weekday(.abbreviated)
            .day()
            .month(.abbreviated)
        let formatted = sameYear
            ? day.formatted(style)
            : day.formatted(style.year())
        return formatted.uppercased()
    }
}

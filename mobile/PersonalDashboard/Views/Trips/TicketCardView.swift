import SwiftUI

/// Wallet-style ticket card rendered inside the trip timeline for items that
/// carry ticket data (#222). Three layouts:
///  - Boarding-pass style (flights / trains): big origin→destination codes,
///    seat / gate / terminal chips, a perforated divider, and a barcode + PNR
///    strip at the bottom.
///  - Event-ticket style (concerts, matches, …): event-type eyebrow, big title,
///    venue + MAP chip, seat / section / row chips, barcode at the bottom.
///  - Stay style (hotels): "STAY" eyebrow with the confirmation code top-right,
///    hotel name, a symmetric check-in → check-out hero (two big dates with a
///    centered bed glyph + nights count on the dashed path), a check-in /
///    check-out time strip, and an address + MAP chip. The perforation + stub
///    only appear when the stay actually has a barcode / attachment; a
///    confirmation-only stay (the common email-imported case) ends cleanly
///    after its location line.
///
/// Which layout renders is driven by `item.kindEnum` (a `.stay` always takes
/// the stay layout) and, for non-stay kinds, `item.isBoardingPassStyle`.
///
/// Flights and events render this card inline on the timeline (they're single
/// moments). A stay is a duration, so its timeline row stays compact and this
/// card is shown inside a detail surface (`StayBookingDetailSheet`) on tap; see
/// `LocalItineraryItem.hasStayBooking`. Items without booking data never reach
/// this view — they render the plain `TripTimelineRow` card unchanged. The card
/// is display-only; the presenting tap is attached by the parent row.
struct TicketCardView: View {
    let item: LocalItineraryItem
    /// The timeline's "HH:mm / Anytime" line, passed down so the card shows the
    /// same time treatment as a normal row. Used by the flight / event layouts;
    /// the stay layout reads `startTime` / `endTime` directly so it can show
    /// both check-in and check-out times independently.
    let timeText: String?

    @Environment(\.openURL) private var openURL

    private var meta: TicketMeta? { item.ticketMeta }

    /// A `.stay` renders the hotel layout; everything else keeps the original
    /// boarding-pass / event split.
    private var isStay: Bool { item.kindEnum == .stay }

    var body: some View {
        VStack(spacing: 0) {
            topContent
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.lg)

            // The tear-off stub only exists when there's something scannable to
            // separate. Flights / events always have a barcode or attachment, so
            // they're unchanged; a confirmation-only stay has neither, so its
            // card ends cleanly after the top content (no dangling perforation).
            if item.hasTicket {
                PerforatedDivider()

                barcodeStub
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.md)
                    .padding(.bottom, Space.lg)
            }
        }
        .frame(maxWidth: .infinity)
        // The whole card carries a soft itinerary-accent wash (theme-aware) so it
        // reads as a distinct physical ticket in the timeline, not another row.
        .background(ticketFill, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.ticketBorder, radius: Radius.lg)
        .contentShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }

    /// Subtle top-to-bottom accent gradient. Rich enough to feel like a ticket,
    /// light enough that ink keeps contrast in both light and dark.
    private var ticketFill: LinearGradient {
        LinearGradient(
            colors: [Tokens.ticketTintTop, Tokens.ticketTintBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Top content (layout switch)

    @ViewBuilder
    private var topContent: some View {
        if isStay {
            stayTop
        } else if item.isBoardingPassStyle {
            boardingPassTop
        } else {
            eventTop
        }
    }

    // MARK: Boarding-pass top

    private var boardingPassTop: some View {
        VStack(spacing: Space.lg) {
            // Label bar: "BOARDING PASS" on the left, operator + flight on the
            // right. A caption strip, not the hero.
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text("BOARDING PASS")
                    .font(.edEyebrow)
                    .textCase(.uppercase)
                    .tracking(1.4)
                    .foregroundStyle(Tokens.accent(for: .itineraries))
                Spacer(minLength: Space.sm)
                if !operatorLabel.isEmpty {
                    Text(operatorLabel)
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.inkSoft)
                        .lineLimit(1)
                }
            }

            routeHero
            factsRow(boardingPassFacts)
        }
    }

    /// Symmetric route hero: big airport codes at the outer edges, a centered
    /// plane on a dashed path between them, city + time stacked under each code.
    private var routeHero: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            routeEndpoint(
                code: meta?.originCode,
                city: meta?.originCity,
                time: departureTimeText,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            planeConnector
                .padding(.top, 6)

            routeEndpoint(
                code: meta?.destinationCode,
                city: meta?.destinationCity,
                time: arrivalTimeText,
                alignment: .trailing
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// A centered plane between two short dashed segments: the classic pass
    /// "flight path". Its natural width is balanced by the two `maxWidth:
    /// .infinity` endpoints on either side, keeping the hero symmetric.
    private var planeConnector: some View {
        HStack(spacing: 5) {
            dashSegment
            Image(systemName: "airplane")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Tokens.accent(for: .itineraries))
                .accessibilityHidden(true)
            dashSegment
        }
    }

    private var dashSegment: some View {
        DashedLine()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(Tokens.mutedSoft)
            .frame(width: 16, height: 1)
    }

    /// One end of the route: big code, small city, optional time. `alignment`
    /// pins the stack to its outer edge so the two ends mirror each other.
    private func routeEndpoint(code: String?, city: String?, time: String?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(code ?? "—")
                .font(.edDisplay)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let city, !city.isEmpty {
                Text(city.uppercased())
                    .font(.edEyebrow)
                    .tracking(1.0)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
            }
            if let time, !time.isEmpty {
                // Time reads as a real detail on the pass, not a footnote:
                // bumped to body-medium ink, still subordinate to the display
                // airport code above it.
                Text(time)
                    .font(.edBodyMedium)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
    }

    /// The departure time from the timeline's own time treatment, unless untimed.
    /// Used by the event layout (a single moment) where `timeText` is one time.
    private var departureTime: String? {
        guard let t = timeText, !t.isEmpty, t != "Anytime" else { return nil }
        return t
    }

    /// Departure / arrival times for the boarding-pass hero, derived straight
    /// from the item so each endpoint shows its own clock (the combined
    /// `timeText` pairs both with an arrow, which we don't want per-endpoint).
    /// Both go through the shared UTC-pinned formatter.
    private var departureTimeText: String? {
        guard let t = item.startTime else { return nil }
        return TimelineEntry.itineraryTimeFormatter.string(from: t)
    }

    private var arrivalTimeText: String? {
        guard let t = item.arrivalTime else { return nil }
        return TimelineEntry.itineraryTimeFormatter.string(from: t)
    }

    /// "IndiGo · 6E681" for the label bar, from whatever of the two is present.
    private var operatorLabel: String {
        [meta?.airline, meta?.flightNumber]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // MARK: Event top

    private var eventTop: some View {
        VStack(spacing: Space.md) {
            Text((meta?.eventType?.isEmpty == false ? meta!.eventType! : "TICKET").uppercased())
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(Tokens.accent(for: .itineraries))

            Text(item.title)
                .font(.edTitle)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if !item.venue.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Tokens.muted)
                    Text(item.venue)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(1)
                }
            }

            // Time is the event's primary "when": promoted out of the equal-
            // weight facts strip into a prominent accent-led line under the
            // venue, so it reads first among the details.
            if let time = departureTime {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Tokens.accent(for: .itineraries))
                    Text(time)
                        .font(.edBodyMedium)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.ink)
                        .lineLimit(1)
                }
            }

            if !eventFacts.isEmpty {
                factsRow(eventFacts)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Stay top

    /// Hotel layout: a "STAY" eyebrow with the confirmation code on the right
    /// (mirroring the flight-number placement), the hotel name, a symmetric
    /// check-in → check-out hero, a check-in / check-out time strip, and an
    /// address + MAP line. Every datum appears once: the confirmation lives in
    /// the eyebrow, the nights count on the hero path, and the times in the
    /// facts strip.
    private var stayTop: some View {
        VStack(spacing: Space.lg) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text("STAY")
                    .font(.edEyebrow)
                    .textCase(.uppercase)
                    .tracking(1.4)
                    .foregroundStyle(Tokens.accent(for: .itineraries))
                Spacer(minLength: Space.sm)
                if !confirmationCode.isEmpty {
                    Text(confirmationCode)
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.inkSoft)
                        .lineLimit(1)
                }
            }

            Text(item.title)
                .font(.edTitle)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)

            stayHero

            if !stayFacts.isEmpty {
                factsRow(stayFacts)
            }

            stayLocationLine
        }
        .frame(maxWidth: .infinity)
    }

    /// Symmetric stay hero: big check-in date, a centered bed glyph + nights
    /// count on the dashed path, big check-out date. Collapses to a single
    /// centered date when there's no distinct check-out (nil `endDate` or a
    /// same-day stay) so we never invent a second date or a fake nights count.
    @ViewBuilder
    private var stayHero: some View {
        if hasCheckOut {
            HStack(alignment: .top, spacing: Space.sm) {
                stayEndpoint(label: "CHECK-IN", date: item.dayDate, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                stayConnector
                    .padding(.top, 6)

                stayEndpoint(label: "CHECK-OUT", date: item.endDate ?? item.dayDate, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            stayEndpoint(label: "CHECK-IN", date: item.dayDate, alignment: .center)
                .frame(maxWidth: .infinity)
        }
    }

    /// A centered bed glyph between two short dashed segments (the stay's
    /// "duration path"), with the nights count stacked beneath it. Balances the
    /// two `maxWidth: .infinity` date endpoints on either side, keeping the hero
    /// symmetric like the flight route hero's plane connector.
    private var stayConnector: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                dashSegment
                Image(systemName: "bed.double.fill")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Tokens.accent(for: .itineraries))
                    .accessibilityHidden(true)
                dashSegment
            }
            if let nights = nightsCount {
                Text(nights == 1 ? "1 NIGHT" : "\(nights) NIGHTS")
                    .font(.edEyebrow)
                    .tracking(1.0)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// One end of the stay hero: big date, small "CHECK-IN" / "CHECK-OUT" label.
    /// `alignment` pins the stack to its outer edge so the two ends mirror.
    private func stayEndpoint(label: String, date: Date, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(stayBigDate(date))
                .font(.edDisplay)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.edEyebrow)
                .tracking(1.0)
                .foregroundStyle(Tokens.muted)
                .lineLimit(1)
        }
        .multilineTextAlignment(alignment == .leading ? .leading : (alignment == .trailing ? .trailing : .center))
    }

    /// Address + MAP chip line, reusing the same MAP-pill pattern as the plain
    /// timeline row. Renders only when there's an address to show or a resolvable
    /// maps URL (explicit link, or derived from the address).
    @ViewBuilder
    private var stayLocationLine: some View {
        let hasAddress = !item.address.isEmpty
        let url = item.mapsURL
        if hasAddress || url != nil {
            HStack(alignment: .center, spacing: 6) {
                if hasAddress {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Tokens.muted)
                    Text(item.address)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: Space.sm)
                if let url {
                    stayMapChip(url: url)
                }
            }
        }
    }

    /// The MAP pill. Its own tap target opens Google Maps without triggering the
    /// card's tap (which goes to the scan surface / editor).
    private func stayMapChip(url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "map.fill")
                    .font(.system(size: 10, weight: .regular))
                Text("MAP")
                    .font(.edEyebrow)
                    .textCase(.uppercase)
                    .tracking(1.4)
            }
            .foregroundStyle(Tokens.accent(for: .itineraries))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Tokens.accent(for: .itineraries).opacity(0.12), in: Capsule(style: .continuous))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open in Google Maps")
    }

    // MARK: Stay derived values

    /// "JUL 3" style month + day, formatted in the device calendar (the stay
    /// dates are start-of-day device-local values).
    private func stayBigDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day()).uppercased()
    }

    /// Nights between check-in (`dayDate`) and check-out (`endDate`), or `nil`
    /// when there's no distinct check-out. Never returns 0 or negative — a
    /// same-day / missing check-out collapses the hero instead of showing "0
    /// nights".
    private var nightsCount: Int? {
        guard let end = item.endDate else { return nil }
        let cal = Calendar.current
        let inDay = cal.startOfDay(for: item.dayDate)
        let outDay = cal.startOfDay(for: end)
        let n = cal.dateComponents([.day], from: inDay, to: outDay).day ?? 0
        return n > 0 ? n : nil
    }

    /// Whether to render the symmetric two-date hero vs the collapsed single date.
    private var hasCheckOut: Bool { nightsCount != nil }

    /// Check-in / check-out times, formatted with the same UTC-pinned formatter
    /// as the timeline so they show the stated booking time regardless of the
    /// device timezone. `nil` when the corresponding time wasn't set.
    private var checkInTimeText: String? {
        guard let t = item.startTime else { return nil }
        return TimelineEntry.itineraryTimeFormatter.string(from: t)
    }

    private var checkOutTimeText: String? {
        guard let t = item.endTime else { return nil }
        return TimelineEntry.itineraryTimeFormatter.string(from: t)
    }

    // MARK: - Facts

    /// Boarding-pass facts: the four canonical slots always render so the grid
    /// stays a balanced 4-column strip. Unknown gate/terminal show an em dash
    /// (via `TicketField`) rather than a fabricated value.
    private var boardingPassFacts: [TicketFact] {
        [
            TicketFact(label: "Seat",     value: item.seat, allowDash: true),
            TicketFact(label: "Gate",     value: TicketField.code(item.gate), allowDash: true),
            TicketFact(label: "Terminal", value: TicketField.code(meta?.terminal), allowDash: true),
            TicketFact(label: "Cabin",    value: meta?.cabin, allowDash: true)
        ]
    }

    /// Event facts: only the slots that carry a real value, so a sparse ticket
    /// doesn't show empty columns. Time is deliberately excluded here: it's
    /// promoted to its own prominent line above the facts strip (see `eventTop`).
    private var eventFacts: [TicketFact] {
        [
            TicketFact(label: "Section", value: meta?.section),
            TicketFact(label: "Row",     value: meta?.row),
            TicketFact(label: "Seat",    value: item.seat.isEmpty ? nil : item.seat)
        ].filter { $0.value != nil }
    }

    /// Stay facts: the check-in and check-out times, each shown only when set.
    /// A balanced strip of whatever exists (0, 1, or 2 columns). Nights and the
    /// confirmation code deliberately aren't repeated here — they already live
    /// on the hero path and in the eyebrow respectively.
    private var stayFacts: [TicketFact] {
        [
            TicketFact(label: "Check-in",  value: checkInTimeText),
            TicketFact(label: "Check-out", value: checkOutTimeText)
        ].filter { $0.value != nil }
    }

    private func factsRow(_ facts: [TicketFact]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                if index > 0 {
                    Rectangle()
                        .fill(Tokens.ticketFactRule)
                        .frame(width: 0.5, height: 26)
                }
                TicketFactCell(fact: fact)
            }
        }
    }

    // MARK: - Barcode stub (below the perforation)

    /// The tear-off stub: a white panel (both themes) with the code centered and
    /// the PNR / reference centered beneath, so it reads as a scannable ticket
    /// stub rather than a lopsided thumbnail.
    private var barcodeStub: some View {
        VStack(spacing: Space.sm) {
            BarcodeImageView(
                payload: item.barcodePayload,
                symbology: item.barcodeSymbology,
                attachmentPath: item.attachmentPath,
                height: stubBarcodeHeight,
                compact: true,
                alignment: .center
            )

            // A stay already shows its confirmation in the eyebrow, so the stub
            // stays code-free (just the scannable barcode). Flights / events
            // keep their PNR / REF line beneath the code.
            if !confirmationCode.isEmpty && !isStay {
                HStack(spacing: 6) {
                    Text(pnrLabel)
                        .font(.edEyebrow)
                        .tracking(1.4)
                        .foregroundStyle(Tokens.ticketStubMuted)
                    Text(confirmationCode)
                        .font(.edMono)
                        .foregroundStyle(Tokens.ticketStubInk)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.md)
        .padding(.horizontal, Space.md)
        .background(Tokens.ticketStub, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    /// A square QR/Aztec wants more height than a wide 1D/PDF417 strip.
    private var stubBarcodeHeight: CGFloat {
        switch BarcodeSymbology(rawValue: item.barcodeSymbology) ?? .other {
        case .qr, .aztec, .other: return 84
        case .pdf417, .code128:   return 52
        }
    }

    private var confirmationCode: String {
        item.sourceConfirmation.trimmingCharacters(in: .whitespaces)
    }

    private var pnrLabel: String {
        item.isBoardingPassStyle ? "PNR" : "REF"
    }
}

// MARK: - Stay booking detail sheet

/// The hub for a booked stay (#222). A stay is a duration, not a moment, so it
/// stays a compact row on the timeline; tapping it presents this full-screen
/// surface (a `.fullScreenCover`, matching TicketScanView) with the full tinted
/// stay card and the relevant actions beneath it:
///  - Scan ticket (when a barcode exists) — the high-contrast presentation view.
///  - View original ticket (when a file is attached).
///  - Edit details — routed back to the existing editor by the parent.
///
/// Scan and View-original are presented as children here; Edit is handed to the
/// parent (via `onEdit`) so the editor replaces this surface rather than
/// stacking on top of it (and so it's gone before an in-editor delete). The
/// "Done" toolbar button is the close affordance.
struct StayBookingDetailSheet: View {
    let item: LocalItineraryItem
    /// Invoked when the user taps "Edit details". The parent dismisses this
    /// sheet and opens the itinerary editor.
    let onEdit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingScan = false
    @State private var showingOriginal = false

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: Space.lg) {
                        // The stay layout reads its times from the item, so the
                        // timeline's per-row time line isn't needed here.
                        TicketCardView(item: item, timeText: nil)
                        actions
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle("Stay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
            }
        }
        .fullScreenCover(isPresented: $showingScan) {
            TicketScanView(item: item)
        }
        .sheet(isPresented: $showingOriginal) {
            TicketOriginalViewer(attachmentPath: item.attachmentPath)
        }
    }

    private var actions: some View {
        VStack(spacing: Space.sm) {
            if item.hasBarcode {
                actionRow(icon: "barcode.viewfinder", title: "Scan ticket") {
                    Haptics.light()
                    showingScan = true
                }
            }
            if !item.attachmentPath.isEmpty {
                actionRow(icon: "doc.text.magnifyingglass", title: "View original ticket") {
                    Haptics.light()
                    showingOriginal = true
                }
            }
            actionRow(icon: "pencil", title: "Edit details") {
                onEdit()
            }
        }
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Tokens.accent(for: .itineraries))
                    .frame(width: 24)
                Text(title)
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.mutedSoft)
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - Ticket fact

/// One labelled fact in the card's evenly-distributed facts strip.
private struct TicketFact: Identifiable {
    let id = UUID()
    let label: String
    let value: String?
    /// When true (boarding-pass slots), an absent value renders an em dash so
    /// the 4-column grid stays balanced. Event slots pass false and are filtered
    /// out upstream instead.
    var allowDash: Bool = false

    init(label: String, value: String?, allowDash: Bool = false) {
        self.label = label
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = (trimmed?.isEmpty == false) ? trimmed : nil
        self.allowDash = allowDash
    }
}

/// A centered label-over-value cell that expands to an equal share of the row,
/// so any number of facts distributes symmetrically across the card width.
private struct TicketFactCell: View {
    let fact: TicketFact

    private var isUnknown: Bool { fact.value == nil }

    var body: some View {
        VStack(spacing: 3) {
            Text(fact.label.uppercased())
                .font(.edEyebrow)
                .tracking(1.0)
                .foregroundStyle(Tokens.muted)
            Text(fact.value ?? TicketField.unknownDash)
                .font(.edFootnote)
                .foregroundStyle(isUnknown ? Tokens.mutedSoft : Tokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Perforated divider

/// The classic ticket "tear" line: a dashed rule with a punched notch at each
/// edge. Notches are filled with the page background so they read as holes cut
/// into the card. Purely decorative.
struct PerforatedDivider: View {
    var notch: CGFloat = 14

    var body: some View {
        ZStack {
            DashedLine()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Tokens.borderStrong)
                .frame(height: 1)
                .padding(.horizontal, notch)

            HStack {
                notchCircle
                Spacer()
                notchCircle
            }
        }
        .frame(height: notch)
    }

    private var notchCircle: some View {
        Circle()
            .fill(Tokens.paper)
            .frame(width: notch, height: notch)
            .overlay(
                Circle().strokeBorder(Tokens.border, lineWidth: 0.5)
            )
            // Pull each notch half over the card edge for the punched look.
            .offset(x: 0)
    }
}

/// Horizontal hairline used by the perforation.
private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: - Barcode image view (shared with the scan screen)

/// Renders a scannable barcode from a stored payload + symbology, regenerated
/// on-device with CoreImage. Falls back to the cropped original attachment when
/// the symbology can't be regenerated (e.g. DataMatrix), and to a neutral
/// placeholder when nothing is available. Rendering runs off the main actor and
/// the result is cached in `@State`, so it's cheap inside a scrolling list.
struct BarcodeImageView: View {
    let payload: String
    let symbology: String
    let attachmentPath: String
    /// Target render height in points.
    var height: CGFloat = 64
    /// Compact mode limits the on-card thumbnail width so a wide PDF417 doesn't
    /// dominate the card; the full scan screen uses `compact = false`.
    var compact: Bool = false
    /// Placement of the code within its available width. The timeline card
    /// centers it on the stub; the editor thumbnail keeps the default leading.
    var alignment: Alignment = .leading

    @State private var rendered: UIImage?
    @State private var didAttempt = false

    var body: some View {
        Group {
            if let rendered {
                Image(uiImage: rendered)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: height)
                    .frame(maxWidth: compact ? 180 : .infinity)
                    .frame(maxWidth: .infinity, alignment: alignment)
            } else {
                placeholder
            }
        }
        .task(id: cacheKey) { await renderIfNeeded() }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(Tokens.surface2)
            .frame(height: height)
            .frame(maxWidth: compact ? 180 : .infinity)
            .frame(maxWidth: .infinity, alignment: alignment)
            .overlay(
                Image(systemName: "barcode")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Tokens.mutedSoft)
            )
    }

    private var cacheKey: String { "\(symbology)|\(payload.count)|\(attachmentPath)|\(Int(height))" }

    private func renderIfNeeded() async {
        guard rendered == nil, !didAttempt else { return }
        didAttempt = true
        let payloadCopy = payload
        let symbol = BarcodeSymbology(rawValue: symbology) ?? .other
        // Regenerate off the main actor; CoreImage + UIGraphicsImageRenderer are
        // safe off-main and this keeps scrolling smooth.
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            if let regenerated = BarcodeService.render(payload: payloadCopy, symbology: symbol, targetLongEdge: 900) {
                return regenerated
            }
            return nil
        }.value
        if let image {
            rendered = image
            return
        }
        // Fall back to the original attachment, cropped to the barcode if we can
        // re-detect it (bounding box isn't persisted).
        if let fallback = await loadAttachmentBarcodeCrop() {
            rendered = fallback
        }
    }

    /// Load the original attachment and crop to its barcode's bounding box when
    /// detectable, so the fallback shows the code rather than the whole ticket.
    private func loadAttachmentBarcodeCrop() async -> UIImage? {
        guard !attachmentPath.isEmpty,
              let url = TicketStorage.shared.load(relativePath: attachmentPath) else { return nil }
        let isPDF = TicketStorage.isPDF(attachmentPath)
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let base: UIImage?
            if isPDF {
                let data = (try? Data(contentsOf: url))
                base = data.flatMap { BarcodeService.renderFirstPage(pdfData: $0) }
            } else {
                base = UIImage(contentsOfFile: url.path)
            }
            guard let base else { return nil }
            if let decoded = BarcodeService.decode(image: base) {
                return BarcodeService.crop(image: base, toNormalized: decoded.boundingBox)
            }
            return base
        }.value
    }
}

import Foundation

/// One card in the Wallet, whatever created it (#398).
///
/// The wallet is a VIEW over existing data, not a second copy of it. A trip's
/// boarding pass keeps living on its `LocalItineraryItem`; a card added straight
/// to the wallet lives on a `LocalWalletCard`. This type is the common shape the
/// list sorts, groups and renders, so nothing downstream of `build` knows how
/// many sources there are.
///
/// ### Adding a source
///
/// Adding one means: a case on `Source` (with its label + icon), a parameter on
/// `build`, and a mapping loop. Nothing else in the wallet changes. Task-attached
/// tickets are being built in parallel and land exactly here — see the `task`
/// note on `Source`.
struct WalletEntry: Identifiable {

    enum Source: Equatable {
        /// A standalone card, added straight to the wallet. Editable and
        /// deletable in place.
        case wallet(cardID: UUID)

        /// A ticket hanging off a trip's timeline item. Read-only in the wallet:
        /// tapping through opens the trip that owns it, because that is where
        /// its day, ordering and trip context are edited.
        case trip(itemID: UUID, tripID: UUID, tripName: String)

        // SEAM: task-attached tickets (built in parallel).
        //
        //   case task(todoID: UUID, taskTitle: String)
        //
        // Add the case, give it a `label`/`icon`/`isEditableInWallet` arm below,
        // then extend `build` with the todos and map the ones carrying ticket
        // data. `TicketCardData` needs a matching `init(_ todo: LocalTodo)`
        // projection; everything else here already works generically.

        /// Chip text shown above the card.
        var label: String {
            switch self {
            case .wallet:                      return "Wallet"
            case .trip(_, _, let tripName):    return tripName
            }
        }

        /// SF Symbol for the chip.
        var icon: String {
            switch self {
            case .wallet: return "wallet.pass"
            case .trip:   return "airplane"
            }
        }

        /// Whether the wallet can edit and delete this card itself. False for
        /// borrowed cards, which route back to the surface that owns them so
        /// there is exactly one place each record is edited.
        var isEditableInWallet: Bool {
            switch self {
            case .wallet: return true
            case .trip:   return false
            }
        }
    }

    let source: Source
    let card: TicketCardData

    /// The day the card belongs to (start-of-day, device-local). Sorting key.
    let day: Date

    /// Last day the card is still worth presenting. Equals `day` for a moment
    /// (a flight, a concert) and the check-out day for a stay, so a hotel card
    /// stays in Upcoming for the whole stay rather than dropping to Past on the
    /// morning of check-in.
    let validThrough: Date

    /// The "HH:mm → HH:mm" / "Anytime" line, formatted exactly as the trip
    /// timeline formats it (same UTC-pinned formatter, so a card reads the same
    /// in both places).
    let timeText: String?

    var id: String {
        switch source {
        case .wallet(let cardID):      return "wallet:\(cardID.uuidString)"
        case .trip(let itemID, _, _):  return "trip:\(itemID.uuidString)"
        }
    }

    /// `true` when this card has not passed yet, evaluated day-granularly so a
    /// card stays Upcoming for the whole of its own day (you scan today's
    /// boarding pass at 22:00, not just before its departure minute).
    func isUpcoming(asOf today: Date) -> Bool {
        validThrough >= today
    }
}

// MARK: - Grouping

/// The wallet's two groups, each already sorted.
struct WalletGroups {
    /// Not yet past, SOONEST FIRST. The card you are about to scan is the one
    /// you need at the top of the screen; a reverse-chronological upcoming list
    /// would bury today's boarding pass under next year's concert. Matches how
    /// `TripsView` orders its Active / Upcoming groups.
    var upcoming: [WalletEntry] = []

    /// Already past, MOST RECENT FIRST, so the list reads newest-to-oldest
    /// downward and old cards sink to the bottom.
    var past: [WalletEntry] = []

    var isEmpty: Bool { upcoming.isEmpty && past.isEmpty }
    var total: Int { upcoming.count + past.count }
}

extension WalletEntry {

    /// Build the wallet's entries from every source.
    ///
    /// - Parameters:
    ///   - cards: every standalone `LocalWalletCard`.
    ///   - itineraryItems: every `LocalItineraryItem`. Only those carrying
    ///     ticket data are taken; the rest are ordinary timeline rows and have
    ///     no card to show.
    ///   - trips: used only to resolve a trip's name for the source chip. An
    ///     item whose trip has vanished is still shown, labelled "Trip", rather
    ///     than dropped: the ticket is the user's, the trip is just context.
    static func build(
        cards: [LocalWalletCard],
        itineraryItems: [LocalItineraryItem],
        trips: [LocalTrip]
    ) -> [WalletEntry] {
        var tripNames: [UUID: String] = [:]
        for trip in trips { tripNames[trip.clientUUID] = trip.name }

        var out: [WalletEntry] = []
        out.reserveCapacity(cards.count + itineraryItems.count)

        for card in cards {
            let data = TicketCardData(card)
            out.append(
                WalletEntry(
                    source: .wallet(cardID: card.clientUUID),
                    card: data,
                    day: card.dayDate,
                    validThrough: card.endDate ?? card.dayDate,
                    timeText: timeLine(for: data)
                )
            )
        }

        for item in itineraryItems {
            // `hasTicket` covers flights and events (an attachment and/or a
            // barcode). `hasStayBooking` additionally covers the common
            // email-imported hotel case, which has a confirmation code and
            // nothing scannable but is still a card you show at a desk.
            guard item.hasTicket || item.hasStayBooking else { continue }
            let data = TicketCardData(item)
            out.append(
                WalletEntry(
                    source: .trip(
                        itemID: item.clientUUID,
                        tripID: item.tripUUID,
                        tripName: tripNames[item.tripUUID] ?? "Trip"
                    ),
                    card: data,
                    day: item.dayDate,
                    validThrough: item.endDate ?? item.dayDate,
                    timeText: timeLine(for: data)
                )
            )
        }

        return out
    }

    /// Split into upcoming / past and sort each group. `today` is start-of-day.
    static func grouped(_ entries: [WalletEntry], today: Date) -> WalletGroups {
        var groups = WalletGroups()
        for entry in entries {
            if entry.isUpcoming(asOf: today) {
                groups.upcoming.append(entry)
            } else {
                groups.past.append(entry)
            }
        }
        // Sort on (day, time-of-day) so two cards on the same day order by their
        // printed time, and a timed card comes before an untimed one. `.distantPast`
        // for a missing time keeps untimed cards last within their day.
        let key: (WalletEntry) -> (Date, Date) = { ($0.day, $0.card.startTime ?? .distantPast) }
        groups.upcoming.sort { key($0) < key($1) }
        groups.past.sort { key($0) > key($1) }
        return groups
    }

    /// The card's time line, mirroring `TimelineEntry.dateTimeLine`: a stay
    /// shows its check-in time, a moment shows "departure → arrival" when both
    /// are known, and an untimed card says "Anytime".
    private static func timeLine(for card: TicketCardData) -> String {
        let format: (Date) -> String = { TimelineEntry.itineraryTimeFormatter.string(from: $0) }
        if card.isStay {
            guard let checkIn = card.startTime else { return "Check-in" }
            return "Check-in · \(format(checkIn))"
        }
        guard let start = card.startTime else { return "Anytime" }
        if let arrival = card.arrivalTime {
            return "\(format(start)) → \(format(arrival))"
        }
        return format(start)
    }
}

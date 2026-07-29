import SwiftUI

/// Wallet-style ticket card for a task attachment (#399).
///
/// A task-shaped sibling of the itinerary's `TicketCardView` rather than a
/// refactor of it: that view carries three travel layouts (boarding pass, event,
/// stay) driven off `LocalItineraryItem`, is live, and its facts cells are
/// `private`. This card has one layout and reads a value type.
///
/// What it does reuse, verbatim, is the visual language: the `Tokens.ticket*`
/// wash, `PerforatedDivider` for the tear, and `BarcodeImageView` for the stub —
/// including that view's fallback chain to a crop of the original when a
/// symbology can't be regenerated. The accent is the Tasks indigo, not the
/// itinerary purple, so the card reads as belonging to this section.
///
/// Display-only. The presenting tap is attached by the parent.
struct TaskTicketCardView: View {
    let ticket: TaskTicket
    /// Shown as the headline when the extractor could not read an event name off
    /// the ticket. The owning task's title is always a better fallback than an
    /// empty card.
    let taskTitle: String

    /// Whether the file backing this ticket is present on this device. When it is
    /// not, the card says so instead of implying the attachment is gone for good.
    var fileIsPresent: Bool = true

    private var meta: TicketMeta? { ticket.ticketMeta }

    private var accent: Color { Tokens.accent(for: .tasks) }

    var body: some View {
        VStack(spacing: 0) {
            topContent
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)

            // The tear only exists when there is something scannable to separate.
            // A ticket that is only a stored file ends cleanly after its details
            // rather than dangling a perforation over an empty stub.
            if ticket.hasBarcode {
                PerforatedDivider()

                barcodeStub
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.md)
                    .padding(.bottom, Space.lg)
            } else if !fileIsPresent {
                PerforatedDivider()

                missingFileNote
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.md)
                    .padding(.bottom, Space.lg)
            }
        }
        .background(ticketFill, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.ticketBorder, radius: Radius.lg)
    }

    /// The soft accent wash, theme-aware in both directions.
    private var ticketFill: LinearGradient {
        LinearGradient(
            colors: [Tokens.ticketTintTop, Tokens.ticketTintBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Top content

    private var topContent: some View {
        VStack(spacing: Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(eyebrow)
                    .font(.edEyebrow)
                    .textCase(.uppercase)
                    .tracking(1.4)
                    .foregroundStyle(accent)
                Spacer(minLength: Space.sm)
                if !ticket.reference.isEmpty {
                    Text(ticket.reference)
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.inkSoft)
                        .lineLimit(1)
                }
            }

            Text(ticket.displayTitle(fallback: taskTitle))
                .font(.edTitle)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)

            if !ticket.venue.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Tokens.muted)
                    Text(ticket.venue)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }

            // When is the thing you check first, so it is promoted out of the
            // equal-weight facts strip into its own accent-led line.
            if let when = whenText {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(accent)
                    Text(when)
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            if !facts.isEmpty {
                factsRow
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The eyebrow carries the event type when the extractor read one, so a match
    /// ticket says MATCH and an appointment card says APPOINTMENT.
    private var eyebrow: String {
        let type = meta?.eventType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return type.isEmpty ? "TICKET" : type.uppercased()
    }

    /// Date and printed time on one line. The time is rendered exactly as it was
    /// read off the ticket — never reformatted, because the number here has to
    /// match the number the gate is reading (see `LocalTaskTicket`).
    private var whenText: String? {
        let dateText = ticket.eventDate.map {
            $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        let timeText = ticket.startTimeText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (dateText, timeText.isEmpty) {
        case (let d?, false): return "\(d) · \(timeText)"
        case (let d?, true):  return d
        case (nil, false):    return timeText
        case (nil, true):     return nil
        }
    }

    // MARK: - Facts

    /// Only the slots carrying a real value, so a sparse ticket does not show
    /// empty columns. Unlike the boarding-pass strip there is no canonical set of
    /// four here: an event ticket legitimately has just a seat, or nothing.
    private var facts: [TaskTicketFact] {
        [
            TaskTicketFact(label: "Section", value: meta?.section),
            TaskTicketFact(label: "Row", value: meta?.row),
            TaskTicketFact(label: "Seat", value: ticket.seat),
            TaskTicketFact(label: "Gate", value: ticket.gate)
        ].filter { $0.value != nil }
    }

    private var factsRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                if index > 0 {
                    Rectangle()
                        .fill(Tokens.ticketFactRule)
                        .frame(width: 0.5, height: 26)
                }
                TaskTicketFactCell(fact: fact)
            }
        }
    }

    // MARK: - Stub

    /// The tear-off stub: the barcode centered on a light panel so it reads as a
    /// scannable stub rather than a lopsided thumbnail.
    private var barcodeStub: some View {
        VStack(spacing: Space.sm) {
            BarcodeImageView(
                payload: ticket.barcodePayload,
                symbology: ticket.barcodeSymbology,
                attachmentPath: ticket.attachmentPath,
                height: 62,
                compact: true,
                alignment: .center
            )

            Text("Tap to scan")
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(Tokens.ticketStubMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.md)
        .background(Tokens.ticketStub, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    /// Shown when the row synced across from another device but its bytes did
    /// not. Being explicit about this beats an empty frame that reads as a bug —
    /// the file is not lost, it is just elsewhere.
    private var missingFileNote: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Tokens.mutedSoft)
            Text("The ticket file is on your other device")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Facts plumbing

/// One label-over-value slot. Blank and whitespace-only values collapse to `nil`
/// at init so the card never renders an empty column.
private struct TaskTicketFact: Identifiable {
    let id = UUID()
    let label: String
    let value: String?

    init(label: String, value: String?) {
        self.label = label
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

/// A centered label-over-value cell that takes an equal share of the row, so any
/// number of facts distributes symmetrically across the card width.
private struct TaskTicketFactCell: View {
    let fact: TaskTicketFact

    var body: some View {
        VStack(spacing: 3) {
            Text(fact.label.uppercased())
                .font(.edEyebrow)
                .tracking(1.0)
                .foregroundStyle(Tokens.muted)
            Text(fact.value ?? TicketField.unknownDash)
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

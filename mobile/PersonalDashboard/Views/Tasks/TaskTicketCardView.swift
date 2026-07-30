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

    /// Laid out on the Apple Wallet pass grammar (#413): a header block top right,
    /// then primary, secondary and auxiliary groups, all flush left.
    ///
    /// The previous version centred everything and hung the venue and the time off
    /// glyphs, which read as a stack of captions rather than a pass. Left alignment
    /// with labelled groups is what makes a real pass scannable: the eye lands in one
    /// column and every value sits under the word for what it is. No icons and no
    /// rules between fields, for the same reason Wallet has none — on a card this
    /// small they are noise competing with the values.
    private var topContent: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // Header. The type sits where a pass puts its logo text; the date and
            // time go top right, time over date, which is Luma's own arrangement.
            HStack(alignment: .top, spacing: Space.sm) {
                Text(eyebrow)
                    .font(.edEyebrow)
                    .textCase(.uppercase)
                    .tracking(1.4)
                    .foregroundStyle(accent)
                Spacer(minLength: Space.sm)
                headerWhen
            }

            // Primary: the one thing you are looking for.
            Text(ticket.displayTitle(fallback: taskTitle))
                .font(.edTitle)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Secondary.
            if !ticket.venue.isEmpty {
                labelledGroup("Location") {
                    Text(ticket.venue)
                        .font(.edSubheadline)
                        .foregroundStyle(Tokens.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Auxiliary.
            if !facts.isEmpty {
                auxiliaryRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The header block: printed time over date, right-aligned.
    ///
    /// The time is the label and the date the value, which looks backwards written
    /// down and is right on the card — the time is the smaller, more glanceable half,
    /// and it is the one that must stay verbatim, so it is never reformatted here.
    @ViewBuilder
    private var headerWhen: some View {
        let time = ticket.startTimeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = ticket.eventDate.map {
            $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        if !time.isEmpty || date != nil {
            VStack(alignment: .trailing, spacing: 1) {
                if !time.isEmpty {
                    Text(time)
                        .font(.edEyebrow)
                        .tracking(0.8)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(1)
                }
                if let date {
                    Text(date)
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)
                        .lineLimit(1)
                }
            }
            .fixedSize()
        }
    }

    /// A Wallet field group: the label in small caps over its value.
    private func labelledGroup<Content: View>(
        _ label: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.edEyebrow)
                .tracking(1.0)
                .foregroundStyle(Tokens.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The eyebrow carries the event type when the extractor read one, so a match
    /// ticket says MATCH and an appointment card says APPOINTMENT.
    private var eyebrow: String {
        let type = meta?.eventType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return type.isEmpty ? "TICKET" : type.uppercased()
    }

    // MARK: - Auxiliary fields

    /// Only the slots carrying a real value, so a sparse ticket shows no empty
    /// columns. Unlike the boarding-pass strip there is no canonical set here: an
    /// event ticket legitimately has just a seat, or just a name, or nothing.
    ///
    /// Ordered by how specifically each one gets you to your place. Seat, section and
    /// row are what you read walking in; gate is next; the guest name matters when
    /// there is no seating at all, which is most non-stadium events (and is the field
    /// Wallet itself leads that row with); the booking reference is last, useful only
    /// if something has gone wrong. It moved here from beside the eyebrow, where it
    /// competed with the type for the top line.
    private var facts: [TaskTicketFact] {
        [
            TaskTicketFact(label: "Seat", value: ticket.seat),
            TaskTicketFact(label: "Section", value: meta?.section),
            TaskTicketFact(label: "Row", value: meta?.row),
            TaskTicketFact(label: "Gate", value: ticket.gate),
            TaskTicketFact(label: "Guest", value: meta?.guestName),
            TaskTicketFact(label: "Ref", value: ticket.reference)
        ].filter { $0.value != nil }
    }

    /// The three highest-priority facts. A pass caps this row too, and past three the
    /// values start truncating on the Mac's 360-point popover, which is worse than
    /// leaving the rest to the detail sheet.
    private var shownFacts: [TaskTicketFact] { Array(facts.prefix(3)) }

    /// Left-aligned, natural widths, no rules. Equal-width centred columns were what
    /// made a single fact sit marooned in the middle of the card.
    private var auxiliaryRow: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            ForEach(shownFacts) { fact in
                TaskTicketFactCell(fact: fact)
            }
            Spacer(minLength: 0)
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

/// A left-aligned label-over-value cell sized to its content, so a row of one does
/// not stretch and a row of three packs from the leading edge (#413). Matches how a
/// Wallet pass lays its auxiliary fields out.
private struct TaskTicketFactCell: View {
    let fact: TaskTicketFact

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
        .fixedSize(horizontal: false, vertical: true)
    }
}

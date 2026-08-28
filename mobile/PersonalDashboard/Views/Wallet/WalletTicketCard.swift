import SwiftUI

/// One wallet card drawn as a piece of ticket stock (#398).
///
/// This is the shape the whole wallet is built out of, and both places a card
/// appears use it: the deck (where it collapses to its header and unfolds in
/// place) and the detail surface (where it is always open). One view, so a card
/// cannot look like two different things depending on where you found it.
///
/// The anatomy, top to bottom:
///  - a **coloured header** carrying the kind, the title and the date. Collapsed,
///    this is the entire card, and it is what you read to find the one you want
///    in a stack. It keeps its position and size when the card opens, so nothing
///    jumps.
///  - the **body**: the existing `TicketCardView`, embedded, so the boarding
///    pass / event / stay layouts are the same ones the trip timeline draws.
///  - the **stub**: the barcode on its own white paper, below a dashed tear line.
///
/// The whole thing is clipped to a `TicketShape`, which punches a notch out of
/// each side at the tear line. The notch is a real hole in the outline rather
/// than a circle painted on top, so it works over another card in the stack.
struct WalletTicketCard: View {
    let entry: WalletEntry
    /// Whether the body is showing. False is the collapsed band in the deck.
    var isOpen: Bool = true
    /// Past cards recede. Still legible, clearly not the one to scan today.
    var isPast: Bool = false
    /// Tap the header. `nil` on a surface where there is nothing left to open.
    var onTapHeader: (() -> Void)?
    /// Tap the ticket body — opens the record behind the card.
    var onTapBody: (() -> Void)?
    /// Tap the barcode stub — presents the code (#479). Split from `onTapBody`
    /// because holding a code up at a gate and opening the record behind it are
    /// different intentions, and the stub was inheriting the body's.
    var onTapStub: (() -> Void)?

    /// Where the tear line landed, measured from the body and fed back into the
    /// outline so the notches line up with the dashes.
    @State private var perforationY: CGFloat?
    /// Fallback tear line for a card with no stub (a confirmation-only stay):
    /// the notches sit on the header seam instead, so every card in the wallet
    /// has the same silhouette rather than some being plain rectangles.
    @State private var headerHeight: CGFloat = 0

    /// Drives the one-shot light sweep across the header when a card opens.
    /// `-1` parks it off the leading edge; `1` has it clear of the trailing one.
    @State private var sheen: CGFloat = -1

    private var palette: WalletCardPalette { entry.palette }

    private var notchY: CGFloat? {
        if let perforationY { return perforationY }
        return headerHeight > 0 ? headerHeight : nil
    }

    private var shape: TicketShape {
        TicketShape(cornerRadius: Radius.xl, notchRadius: 11, notchY: notchY)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isOpen {
                TicketCardView(
                    item: entry.card,
                    timeText: entry.timeText,
                    palette: palette,
                    // The header above already carries the title; printing it
                    // again inside the body reads as a mistake.
                    showsTitle: false,
                    embedded: true,
                    onTapBarcode: onTapStub
                )
                .contentShape(Rectangle())
                .onTapGesture { onTapBody?() }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // The body's wash. The header paints over it; the stub paints white over
        // it. Sitting on the container means the two seams have no hairline gap.
        .background(
            LinearGradient(
                colors: [palette.tintTop, palette.tintBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .readingTicketNotch { perforationY = $0 }
        .clipShape(shape)
        .overlay(shape.stroke(palette.border, lineWidth: 1))
        // Depth is what makes a stack read as a stack rather than a list of
        // rectangles. Deeper when open so the card lifts off the ones behind.
        .shadow(
            color: .black.opacity(isOpen ? 0.20 : 0.12),
            radius: isOpen ? 16 : 7,
            x: 0,
            y: isOpen ? 8 : 3
        )
        .opacity(isPast && !isOpen ? 0.72 : 1)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    /// Kind and title on the left, date on the right, over the card's colour.
    /// Two lines in both states, so opening a card never re-flows its header.
    private var header: some View {
        let content = HStack(alignment: .center, spacing: Space.md) {
            Image(systemName: entry.kind.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.bandInk)
                .frame(width: 30, height: 30)
                .background(palette.bandInk.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow)
                    .font(.edEyebrow)
                    .tracking(1.2)
                    .foregroundStyle(palette.bandInk.opacity(0.82))
                    .lineLimit(1)
                Text(entry.card.title)
                    .font(.edBodyMedium)
                    .foregroundStyle(palette.bandInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: Space.sm)

            Text(whenLabel)
                .font(.edFootnote)
                .monospacedDigit()
                .foregroundStyle(palette.bandInk)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 4)
                .background(palette.bandInk.opacity(0.16), in: Capsule())
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(headerFill)
        .overlay(sheenSweep)
        // A run of same-coloured cards (four hotel stays in a row) merges into
        // one block of colour without this: the hairline is the card edge you
        // see in a closed stack.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.bandInk.opacity(0.22))
                .frame(height: 1)
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { headerHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, new in headerHeight = new }
            }
        )
        .contentShape(Rectangle())

        return Group {
            if let onTapHeader {
                Button(action: onTapHeader) { content }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(entry.kind.displayName), \(entry.card.title), \(whenLabel)")
                    .accessibilityHint(isOpen ? "Collapses the card" : "Opens the card")
                    .accessibilityAddTraits(.isButton)
            } else {
                content
            }
        }
    }

    /// A single band of light travelling across the header when the card opens.
    /// Plays once and parks off-screen — a card that shimmers continuously in a
    /// list is a distraction, whereas one sweep reads as the card catching the
    /// light as it turns over.
    private var sheenSweep: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            LinearGradient(
                colors: [.clear, palette.bandInk.opacity(0.30), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(width * 0.28, 60))
            .rotationEffect(.degrees(18))
            .offset(x: sheen * width * 1.4)
        }
        .allowsHitTesting(false)
        .onAppear { if isOpen { playSheen() } }
        .onChange(of: isOpen) { _, open in
            if open { playSheen() } else { sheen = -1 }
        }
    }

    private func playSheen() {
        sheen = -1
        withAnimation(.easeOut(duration: 0.9)) { sheen = 1 }
    }

    /// Diagonal gradient rather than a flat fill: printed stock has a sheen, and
    /// a stack of flat rectangles reads as a UI list no matter what colour it is.
    private var headerFill: LinearGradient {
        LinearGradient(
            colors: [palette.band, palette.bandDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// "BOARDING PASS" on a card the wallet owns, "STAY · ITALY" on one borrowed
    /// from a trip, "EVENT TICKET · SPIDER-MAN" on one borrowed from a task.
    /// Provenance only when it is borrowed: "WALLET" on every standalone card
    /// would be noise on every row.
    private var eyebrow: String {
        let kind = entry.kind.displayName.uppercased()
        switch entry.source {
        case .wallet:
            return kind
        case .trip, .task, .tripDocument:
            let provenance = entry.source.label.uppercased()
            // A task usually IS the thing — "Spider-Man: Brand New Day" the task
            // holding the "Spider-Man: Brand New Day" ticket — and printing the
            // name twice, once above the other, reads as a rendering bug.
            guard provenance != entry.card.title.uppercased() else { return kind }
            return "\(kind) · \(provenance)"
        }
    }

    // MARK: - When

    /// Compact right-hand label: the time when the card is today (that is the
    /// fact you need at a gate), otherwise the date. A year is appended once the
    /// card falls outside this one, so an old pass never reads as this year's.
    private var whenLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(entry.day) {
            if let time = entry.card.startTime {
                return TimelineEntry.itineraryTimeFormatter.string(from: time)
            }
            return "TODAY"
        }
        let sameYear = calendar.component(.year, from: entry.day)
            == calendar.component(.year, from: Date())
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        let text = sameYear
            ? entry.day.formatted(style)
            : entry.day.formatted(style.year())
        return text.uppercased()
    }
}

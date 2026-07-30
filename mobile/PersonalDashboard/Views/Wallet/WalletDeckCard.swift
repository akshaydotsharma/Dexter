import SwiftUI

/// One card in the wallet's stacked deck (#398).
///
/// Collapsed, it is a single coloured band: an icon, the title, and when it is.
/// That band is the whole point of the stack — it is what you read to find the
/// card you want while the rest of it sits hidden under the next one. Expanded,
/// the same band stays put and the full ticket unfolds beneath it, barcode and
/// all.
///
/// The band carries the title in both states so nothing moves or re-flows when a
/// card opens; the ticket body below is told not to draw its own title
/// (`showsTitle: false`) so it is never printed twice.
///
/// Colour comes from the card's kind, so a stay, a boarding pass and an event
/// ticket are told apart at a glance in a closed stack — which is the only way a
/// stack of bands is usable at all.
struct WalletDeckCard: View {
    let entry: WalletEntry
    let isExpanded: Bool
    /// Past cards recede. Still legible, clearly not the one to scan today.
    let isPast: Bool
    /// Tap the band: expand, or collapse if already open.
    let onToggle: () -> Void
    /// Tap the opened ticket, or its Present button: go to the barcode.
    let onOpen: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    let onOpenSource: (() -> Void)?

    private var palette: WalletCardPalette { entry.palette }

    var body: some View {
        VStack(spacing: 0) {
            band
            if isExpanded {
                expandedBody
            }
        }
        .background(palette.tintBottom)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(palette.border, lineWidth: isExpanded ? 0 : 0.5)
        )
        // Depth is what makes a stack read as a stack rather than a list of
        // rectangles. Deeper on the open card so it lifts off the ones behind.
        .shadow(
            color: .black.opacity(isExpanded ? 0.20 : 0.12),
            radius: isExpanded ? 16 : 7,
            x: 0,
            y: isExpanded ? 8 : 3
        )
        .opacity(isPast && !isExpanded ? 0.72 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .contextMenu {
            if let onEdit {
                Button { onEdit() } label: { Label("Edit details", systemImage: "pencil") }
            }
            if let onOpenSource {
                Button { onOpenSource() } label: {
                    Label("Open \(entry.source.label)", systemImage: "arrow.up.forward.app")
                }
            }
            if let onDelete {
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete card", systemImage: "trash")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Band

    /// The always-visible strip. One line: what it is, what it is called, when.
    private var band: some View {
        Button(action: onToggle) {
            HStack(spacing: Space.sm) {
                Image(systemName: entry.kind.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.bandInk)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.card.title)
                        .font(.edBodyMedium)
                        .foregroundStyle(palette.bandInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Provenance only when the card is borrowed: "Wallet" on
                    // every standalone card would be noise on every row.
                    if case .trip = entry.source {
                        Text(entry.source.label)
                            .font(.edEyebrow)
                            .tracking(1.0)
                            .foregroundStyle(palette.bandInk.opacity(0.75))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Space.sm)

                Text(whenLabel)
                    .font(.edFootnote)
                    .monospacedDigit()
                    .foregroundStyle(palette.bandInk.opacity(0.92))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.band)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(palette.bandInk.opacity(0.22))
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.kind.displayName), \(entry.card.title), \(whenLabel)")
        .accessibilityHint(isExpanded ? "Collapses the card" : "Opens the card")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Expanded body

    private var expandedBody: some View {
        VStack(spacing: Space.md) {
            // The ticket itself, in this card's colours, with its title
            // suppressed because the band above already carries it.
            TicketCardView(
                item: entry.card,
                timeText: entry.timeText,
                palette: palette,
                showsTitle: false
            )
            .onTapGesture(perform: onOpen)

            actionRow
        }
        .padding(.horizontal, Space.sm)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.md)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// The one action worth a button rather than a hidden tap. Scanning is the
    /// reason the wallet exists, so it is spelled out instead of relying on the
    /// user guessing that the card is tappable.
    @ViewBuilder
    private var actionRow: some View {
        #if os(iOS)
        if entry.card.hasTicket {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: entry.card.hasBarcode ? "barcode.viewfinder" : "doc.text.magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                    Text(entry.card.hasBarcode ? "Present to scan" : "View ticket")
                        .font(.edBodyMedium)
                }
                .foregroundStyle(palette.bandInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.md)
                .background(palette.band, in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.card.hasBarcode ? "Present to scan" : "View ticket")
        }
        #else
        // macOS has no present-to-scan surface (it needs the brightness and
        // idle-timer control), so the equivalent action is the card detail.
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.expand.vertical")
                    .font(.system(size: 13, weight: .semibold))
                Text("Open card")
                    .font(.edBodyMedium)
            }
            .foregroundStyle(palette.bandInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.sm)
            .background(palette.band, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open card")
        #endif
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

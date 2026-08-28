import SwiftUI

/// One card in the wallet's stacked deck (#398).
///
/// A thin wrapper around `WalletTicketCard` — the ticket itself is shared with
/// the detail surface — adding the things that only make sense inside the deck:
/// the action button under an open card, and the edit / delete / open-source
/// context menu.
///
/// Collapsed, the card is its coloured header alone: kind, title, date. That is
/// what you read to find the card you want while the rest of it sits hidden
/// under the next one. Tapping the header unfolds the full ticket in place.
struct WalletDeckCard: View {
    let entry: WalletEntry
    let isExpanded: Bool
    /// Past cards recede. Still legible, clearly not the one to scan today.
    let isPast: Bool
    /// Tap the header: expand, or collapse if already open.
    let onToggle: () -> Void
    /// The action row's main button: straight to the barcode on iOS, the card
    /// detail on macOS. Nothing a card does changes section any more (#483).
    let onPresent: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    let onOpenSource: (() -> Void)?
    /// Read the stored file again against the current extractor (#484). `nil` for a
    /// card with no extraction behind it to redo.
    let onReread: (() -> Void)?

    private var palette: WalletCardPalette { entry.palette }

    var body: some View {
        VStack(spacing: Space.sm) {
            WalletTicketCard(
                entry: entry,
                isOpen: isExpanded,
                isPast: isPast,
                onTapHeader: onToggle,
                // The barcode goes where the Present button goes (#479): iOS to
                // the scan surface, macOS to the card detail. Tapping a code and
                // pressing the button under it are the same intention.
                onTapStub: onPresent
            )

            if isExpanded {
                actionRow
                    .transition(.opacity)
            }
        }
        .contextMenu {
            if let onEdit {
                Button { onEdit() } label: { Label("Edit details", systemImage: "pencil") }
            }
            if let onOpenSource {
                Button { onOpenSource() } label: {
                    Label("Open \(entry.source.label)", systemImage: "arrow.up.forward.app")
                }
            }
            if let onReread {
                Button { onReread() } label: {
                    Label("Read the ticket again", systemImage: "arrow.clockwise.circle")
                }
            }
            if let onDelete {
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete card", systemImage: "trash")
                }
            }
        }
    }

    /// The actions worth a button rather than a hidden gesture, side by side
    /// below the ticket, the way a pass's actions sit in Apple Wallet.
    ///
    /// Scanning is the reason the wallet exists, so it is spelled out instead of
    /// relying on the user guessing the card is tappable. Edit sits beside it for
    /// a card the wallet owns (#483): the body tap used to reach the editor and
    /// now turns the card over, so without this the only way in would be a
    /// context menu nobody opens.
    private var actionRow: some View {
        HStack(spacing: Space.sm) {
            #if os(iOS)
            if entry.card.hasTicket {
                actionButton(
                    icon: entry.card.hasBarcode ? "barcode.viewfinder" : "doc.text.magnifyingglass",
                    title: entry.card.hasBarcode ? "Present to scan" : "View ticket",
                    action: onPresent
                )
            }
            #else
            // macOS has no present-to-scan surface (it needs the brightness and
            // idle-timer control), so the equivalent action is the card detail.
            actionButton(icon: "rectangle.expand.vertical", title: "Open card", action: onPresent)
            #endif
            if let onEdit {
                actionButton(icon: "pencil", title: "Edit", action: onEdit)
            }
        }
    }

    private func actionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionLabel(icon: icon, title: title)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func actionLabel(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.edBodyMedium)
        }
        .foregroundStyle(palette.bandInk)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.md)
        .background(palette.band, in: Capsule(style: .continuous))
    }
}

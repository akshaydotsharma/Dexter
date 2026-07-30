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
    /// Tap the opened ticket, or its Present button: go to the barcode.
    let onOpen: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    let onOpenSource: (() -> Void)?

    private var palette: WalletCardPalette { entry.palette }

    var body: some View {
        VStack(spacing: Space.sm) {
            WalletTicketCard(
                entry: entry,
                isOpen: isExpanded,
                isPast: isPast,
                onTapHeader: onToggle,
                onTapBody: onOpen
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
            if let onDelete {
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete card", systemImage: "trash")
                }
            }
        }
    }

    /// The one action worth a button rather than a hidden tap. Scanning is the
    /// reason the wallet exists, so it is spelled out instead of relying on the
    /// user guessing that the card is tappable. It sits below the ticket rather
    /// than inside it, the way a pass's actions do in Apple Wallet.
    @ViewBuilder
    private var actionRow: some View {
        #if os(iOS)
        if entry.card.hasTicket {
            Button(action: onOpen) {
                actionLabel(
                    icon: entry.card.hasBarcode ? "barcode.viewfinder" : "doc.text.magnifyingglass",
                    title: entry.card.hasBarcode ? "Present to scan" : "View ticket"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.card.hasBarcode ? "Present to scan" : "View ticket")
        }
        #else
        // macOS has no present-to-scan surface (it needs the brightness and
        // idle-timer control), so the equivalent action is the card detail.
        Button(action: onOpen) {
            actionLabel(icon: "rectangle.expand.vertical", title: "Open card")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open card")
        #endif
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

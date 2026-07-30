import SwiftUI

/// The hub for one wallet card (#398): the full tinted card plus the actions
/// that apply to it.
///
/// A near-sibling of `StayBookingDetailSheet`, which does the same job for a
/// booked stay on the trip timeline, and deliberately the same shape: the card
/// on a paper background, a stack of action rows beneath it, "Done" to close.
///
/// Reached in two situations:
///  - The card has nothing scannable (a typed confirmation code), so tapping it
///    in the list would otherwise open a scan screen with an empty barcode.
///  - macOS, which has no present-to-scan surface at all (it depends on
///    `UIScreen.brightness` and the idle timer), so every card opens here.
///
/// Actions it owns: scan (iOS, when there is a barcode) and view-original.
/// Actions it delegates: edit and open-the-owning-surface, both handed up so the
/// parent can dismiss this first and present the editor in its place rather than
/// stacking sheets.
struct WalletCardDetailSheet: View {
    let entry: WalletEntry
    /// Set for a card the wallet owns. `nil` for a borrowed card, which is
    /// edited where it lives.
    let onEdit: (() -> Void)?
    /// Set for a borrowed card: jumps to the trip that owns it. `nil` for a card
    /// the wallet owns.
    let onOpenSource: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var showingOriginal = false
    #if os(iOS)
    @State private var showingScan = false
    #endif

    private var card: TicketCardData { entry.card }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()

                VStack(spacing: Space.lg) {
                    // The ticket sits in the middle of the page rather than
                    // pinned under the title bar with the rest of the screen
                    // empty below it: this surface exists to show ONE card, and
                    // a card floating in the centre is what that should look
                    // like. A tall card still scrolls.
                    GeometryReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                WalletTicketCard(entry: entry)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: proxy.size.height)
                            .padding(.horizontal, Space.lg)
                        }
                    }

                    actions
                        .padding(.horizontal, Space.lg)
                }
                .padding(.vertical, Space.lg)
            }
            .navigationTitle(entry.source.label)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
            }
        }
        // iOS presents this full-screen, so it already has a definite size to
        // centre the ticket in. A macOS sheet sizes itself to its content, and
        // the centring container has no intrinsic height to offer, so without a
        // floor the sheet collapses to the height of its two action rows and
        // squeezes the card to a sliver.
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 660, idealHeight: 720)
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $showingScan) {
            TicketScanView(pass: ScannablePass(card: card))
        }
        #endif
        .sheet(isPresented: $showingOriginal) {
            TicketOriginalViewer(attachmentPath: card.attachmentPath)
        }
    }

    private var actions: some View {
        VStack(spacing: Space.sm) {
            // Present-to-scan is the iOS-only gate idiom (brightness + idle
            // timer), so macOS goes straight to the stored file instead.
            #if os(iOS)
            if card.hasBarcode {
                actionRow(icon: "barcode.viewfinder", title: "Present to scan") {
                    Haptics.light()
                    showingScan = true
                }
            }
            #endif
            if !card.attachmentPath.isEmpty {
                actionRow(icon: "doc.text.magnifyingglass", title: "View original ticket") {
                    Haptics.light()
                    showingOriginal = true
                }
            }
            if let onEdit {
                actionRow(icon: "pencil", title: "Edit details", action: onEdit)
            }
            if let onOpenSource {
                actionRow(
                    icon: "arrow.up.forward.app",
                    title: "Open \(entry.source.label)",
                    action: onOpenSource
                )
            }
        }
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Tokens.accent(for: .wallet))
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

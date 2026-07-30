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
    @Environment(\.openURL) private var openURL
    @State private var showingOriginal = false
    #if os(iOS)
    @State private var showingScan = false
    @State private var showingApplePass = false
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
                                if !backFields.isEmpty { passBack }
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
        .sheet(isPresented: $showingApplePass) {
            if let passData = storedPassData {
                AddPassToAppleWallet(data: passData) { showingApplePass = false }
                    .ignoresSafeArea()
            }
        }
        #endif
        .sheet(isPresented: $showingOriginal) {
            TicketOriginalViewer(attachmentPath: card.attachmentPath)
        }
    }

    /// The actions as a single row of icon tiles rather than a stack of
    /// full-width rows.
    ///
    /// Three stacked rows ate roughly a third of an iPhone screen, which pushed
    /// the boarding pass — the thing this surface exists to show — off the
    /// bottom and made you scroll to see your own ticket. Side by side they cost
    /// one row's height for all of them, and an icon over a short word is as
    /// readable as a full sentence with a chevron when there are only ever two
    /// or three of them.
    private var actions: some View {
        HStack(spacing: Space.sm) {
            // Present-to-scan is the iOS-only gate idiom (brightness + idle
            // timer), so macOS goes straight to the stored file instead.
            #if os(iOS)
            if card.hasBarcode {
                actionTile(icon: "barcode.viewfinder", title: "Scan") {
                    Haptics.light()
                    showingScan = true
                }
            }
            #endif
            // A `.pkpass` has no page to look at — it is a signed data bundle, so the
            // original-ticket viewer would show its "unavailable" state on a file that
            // is intact (#420). The system's own Wallet is the right place to see it,
            // and it exists only on iOS, so the Mac offers neither.
            #if os(iOS)
            if let passData = storedPassData, AddPassToAppleWallet.pass(from: passData) != nil {
                actionTile(icon: "wallet.pass", title: "Apple Wallet") {
                    Haptics.light()
                    showingApplePass = true
                }
            } else if showsOriginal {
                actionTile(icon: "doc.text.magnifyingglass", title: "Original") {
                    Haptics.light()
                    showingOriginal = true
                }
            }
            #else
            if showsOriginal {
                actionTile(icon: "doc.text.magnifyingglass", title: "Original") {
                    Haptics.light()
                    showingOriginal = true
                }
            }
            #endif
            if let onEdit {
                actionTile(icon: "pencil", title: "Edit", action: onEdit)
            }
            // The event's own page. Apple Wallet lists this on the back of a pass and
            // so do we (#412), which makes this surface the right home for it — it is
            // the thing you open the day before, not the thing you hold up at the door.
            // Hidden outright when no page is stored, rather than offering an action
            // that goes nowhere.
            if let url = eventPageURL {
                actionTile(icon: "safari", title: "Event page") {
                    Haptics.light()
                    openURL(url)
                }
            }
            if let onOpenSource {
                actionTile(
                    icon: "arrow.up.forward.app",
                    title: entry.source.label,
                    action: onOpenSource
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Whether there is a file the original-ticket viewer can actually render.
    private var showsOriginal: Bool {
        !card.attachmentPath.isEmpty && !TicketStorage.isPass(card.attachmentPath)
    }

    #if os(iOS)
    /// The stored `.pkpass` bytes, when that is what the attachment is. Read lazily on
    /// each evaluation rather than held in state: it is one small file read, and it
    /// cannot go stale against a card the user just edited.
    private var storedPassData: Data? {
        guard TicketStorage.isPass(card.attachmentPath),
              let url = TicketStorage.taskTickets.load(relativePath: card.attachmentPath)
        else { return nil }
        return try? Data(contentsOf: url)
    }
    #endif

    /// The stored event page, coercing a bare host to https so a hand-typed value
    /// still opens. `nil` when there is nothing usable.
    private var eventPageURL: URL? {
        guard let raw = card.meta?.eventURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(string: "https://\(raw)")
    }

    // MARK: - The back of the pass

    /// Fields the issuer put on the back of the pass (#420).
    private var backFields: [TicketMeta.PassField] {
        card.meta?.backFields ?? []
    }

    /// The back of the pass, rendered as the issuer wrote it.
    ///
    /// A pass carries more than fits on its face — the holder's email, the admission
    /// type, an organiser, a refund policy — and Apple's answer is to let you turn the
    /// card over. This is that: whatever the document printed on its back, in its own
    /// order, under its own labels. Nothing here is interpreted, which is why a field
    /// this app has never heard of still shows up correctly.
    ///
    /// Absent entirely for a card with no back fields, so a hand-typed wallet card is
    /// exactly as it was.
    private var passBack: some View {
        VStack(spacing: 0) {
            ForEach(Array(backFields.enumerated()), id: \.element) { index, field in
                if index > 0 {
                    Rectangle()
                        .fill(Tokens.border)
                        .frame(height: 0.5)
                }
                backRow(field)
            }
        }
        .padding(.horizontal, Space.md)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
        .padding(.top, Space.lg)
    }

    /// One back field. A value that is a URL becomes a tap target showing its host,
    /// because the alternative is 180 characters of query string wrapped across four
    /// lines of a card.
    @ViewBuilder
    private func backRow(_ field: TicketMeta.PassField) -> some View {
        if let url = field.url {
            Button {
                Haptics.light()
                openURL(url)
            } label: {
                backRowBody(
                    label: field.label,
                    value: url.host ?? field.value,
                    isLink: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(field.label), opens \(url.host ?? "link")")
        } else {
            backRowBody(label: field.label, value: field.value, isLink: false)
        }
    }

    private func backRowBody(label: String, value: String, isLink: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(label.uppercased())
                .font(.edEyebrow)
                .tracking(1.0)
                .foregroundStyle(Tokens.muted)
            Spacer(minLength: Space.sm)
            Text(value)
                .font(.edFootnote)
                .foregroundStyle(isLink ? entry.palette.accent : Tokens.ink)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
            if isLink {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(entry.palette.accent)
            }
        }
        .padding(.vertical, Space.md)
        .contentShape(Rectangle())
    }

    private func actionTile(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(entry.palette.accent)
                Text(title)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.md)
            .padding(.horizontal, Space.sm)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

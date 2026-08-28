import SwiftUI

/// The back of a wallet card (#481).
///
/// A pass has two sides for a reason. The face carries the handful of facts you
/// read at a door, sized so every card in the deck is the same height; the back
/// carries everything else, as a plain label / value table in the issuer's own
/// words. Before this, all of it was on the face — the Monza F1 pass printed nine
/// internal codes ("Progr.sessivo", "S.F", "Cod.Rich.Em.Sigillo") above the QR
/// you had come for, and every card was a different height as a result.
///
/// Deliberately unstyled beyond the table. Nothing here is interpreted, so a
/// field this app has never heard of still renders correctly, and a value that is
/// a link becomes a tap target showing its host rather than 180 characters of
/// query string.
///
/// It draws the same tear line at the same height as the face, so turning a card
/// over changes what it says and nothing about what it is.
struct TicketCardBack: View {
    let fields: TicketCardFields
    let palette: WalletCardPalette

    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(fields.back.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle()
                            .fill(palette.factRule)
                            .frame(height: 0.5)
                    }
                    backRow(row)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
        }
        .frame(height: TicketCardMetrics.openBody)
        // The tear line stays where the face put it, so the card's outline does
        // not move under the flip. Rows scroll past it the way the print on a
        // real ticket's back runs across its perforation.
        .overlay(alignment: .top) {
            PerforatedDivider(cutout: true, lineColor: palette.factRule)
                .padding(.top, TicketCardMetrics.hero + TicketCardMetrics.face)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func backRow(_ row: TicketCardFields.Row) -> some View {
        if let url = row.url {
            Button {
                Haptics.light()
                openURL(url)
            } label: {
                rowBody(label: row.label, value: url.host ?? row.value, isLink: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(row.label), opens \(url.host ?? "link")")
        } else {
            rowBody(label: row.label, value: row.value, isLink: false)
        }
    }

    private func rowBody(label: String, value: String, isLink: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(label.uppercased())
                .font(.edEyebrow)
                .tracking(1.0)
                .foregroundStyle(Tokens.muted)
            Spacer(minLength: Space.sm)
            Text(value)
                .font(.edFootnote)
                .foregroundStyle(isLink ? palette.accent : Tokens.ink)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
            if isLink {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
        }
        .padding(.vertical, Space.md)
        .contentShape(Rectangle())
    }
}

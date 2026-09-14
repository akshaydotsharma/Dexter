import SwiftUI

/// The printed pages of the trip expense report (#528).
///
/// These views are never shown in the app. They exist to be handed to
/// `ImageRenderer`, one page at a time, so the export is real vector text in a
/// PDF rather than a screenshot.
///
/// The report is a document that leaves Dexter — it goes to a group chat, and
/// the people reading it do not have the app. So it is deliberately NOT
/// theme-aware: it uses the Editorial Calm ramp and spacing the app uses, with
/// the light values of the palette pinned as literals. A dark-mode export would
/// print as a black rectangle.
///
/// Two deliberate departures from how the same numbers are drawn in the app,
/// both so the exported PDF stays SEARCHABLE. `document.string` was the check
/// that found them:
///
/// - **No `.monospacedDigit()`.** On Inter it resolves through a substituted
///   font whose glyphs carry no usable Unicode mapping, so every amount and
///   every date came back out of the PDF blank while rendering perfectly.
///   Amounts sit in fixed, right-aligned columns, so they line up without it.
/// - **Eyebrow tracking is 1.2, not the ramp's 1.4.** Above roughly 1.3 the
///   letter gaps read as word breaks to a text extractor, and "DAILY LEDGER"
///   comes back as "DA I LY L E D G E R" — unfindable with Cmd-F.
enum ReportInk {
    static let paper       = Color(hex: 0xFFFFFF)
    static let panel       = Color(hex: 0xF8F5EE)
    static let border      = Color(hex: 0xE8E2D2)
    static let divider     = Color(hex: 0xEFE9DA)
    static let ink         = Color(hex: 0x1F1B16)
    static let inkSoft     = Color(hex: 0x4A4339)
    static let muted       = Color(hex: 0x7B7263)
    static let mutedSoft   = Color(hex: 0xA89E8A)
    /// The Finance accent, which is the section this report belongs to.
    static let accent      = Color(hex: 0x047857)
    static let accentSoft  = Color(hex: 0xD7EBE2)
    /// Money coming back in.
    static let credit      = Color(hex: 0x15803D)
}

// MARK: - Cover

struct TripReportCoverPage: View {
    let cover: TripExpenseReport.Cover

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trip expense report")
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(ReportInk.accent)

            Spacer().frame(height: Space.md)

            Text(cover.tripName)
                .font(.system(size: 40, weight: .regular, design: .serif))
                .foregroundStyle(ReportInk.ink)
                .tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: Space.xs)

            Text(cover.dateRange)
                .font(.edBody)
                .foregroundStyle(ReportInk.muted)

            Spacer().frame(height: Space.xl)

            Rectangle()
                .fill(ReportInk.ink)
                .frame(width: 56, height: 2)

            Spacer().frame(height: Space.xl)

            // The three numbers someone opens this document for.
            HStack(alignment: .top, spacing: Space.lg) {
                headline(label: "Group total", value: cover.groupTotal, emphasis: true)
                headline(label: cover.selectionTitle, value: cover.selectionShare, emphasis: false)
                headline(
                    label: "Expenses",
                    value: "\(cover.expenseCount)",
                    emphasis: false
                )
            }

            Spacer().frame(height: Space.xl)

            panel(title: "Who was on this trip", body: cover.participants.joined(separator: " · "))

            Spacer().frame(height: Space.md)

            VStack(alignment: .leading, spacing: Space.sm) {
                sentence(cover.filterSentence)
                sentence(cover.currencySentence)
                sentence(cover.settlementSentence)
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReportInk.panel)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .stroke(ReportInk.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))

            Spacer(minLength: 0)

            Text("Exported \(cover.exportedOn) from Dexter")
                .font(.edCaption)
                .foregroundStyle(ReportInk.mutedSoft)
        }
        .frame(
            width: ReportPageMetrics.contentWidth,
            height: ReportPageMetrics.height - ReportPageMetrics.margin * 2,
            alignment: .topLeading
        )
        .padding(ReportPageMetrics.margin)
        .frame(width: ReportPageMetrics.width, height: ReportPageMetrics.height, alignment: .topLeading)
        .background(ReportInk.paper)
    }

    private func headline(label: String, value: String, emphasis: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label)
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(ReportInk.muted)
                .lineLimit(1)
            Text(value)
                .font(.system(size: emphasis ? 26 : 20, weight: .regular, design: .serif))
                .foregroundStyle(emphasis ? ReportInk.ink : ReportInk.inkSoft)
                .tracking(-0.4)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func panel(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(ReportInk.muted)
            Text(body)
                .font(.edBody)
                .foregroundStyle(ReportInk.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sentence(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Circle()
                .fill(ReportInk.accent)
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.edFootnote)
                .foregroundStyle(ReportInk.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Content page

struct TripReportContentPage: View {
    let blocks: [ReportBlock]
    /// Running head, so a page that arrives on its own still names the trip.
    let tripName: String
    let currencyCode: String
    let pageNumber: Int
    let pageCount: Int

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    ReportBlockView(block: block)
                        .frame(
                            width: ReportPageMetrics.contentWidth,
                            height: block.height,
                            alignment: .leading
                        )
                }
                Spacer(minLength: 0)
            }
            .frame(
                width: ReportPageMetrics.contentWidth,
                height: ReportPageMetrics.contentHeight,
                alignment: .topLeading
            )

            footer
        }
        .padding(ReportPageMetrics.margin)
        .frame(width: ReportPageMetrics.width, height: ReportPageMetrics.height, alignment: .topLeading)
        .background(ReportInk.paper)
    }

    private var footer: some View {
        VStack(spacing: Space.xs) {
            Rectangle()
                .fill(ReportInk.divider)
                .frame(height: 1)
            HStack {
                Text("\(tripName) · expenses in \(currencyCode)")
                    .lineLimit(1)
                Spacer()
                Text("Page \(pageNumber) of \(pageCount)")
            }
            .font(.edCaption)
            .foregroundStyle(ReportInk.mutedSoft)
        }
        .frame(width: ReportPageMetrics.contentWidth, height: ReportPageMetrics.footerHeight, alignment: .bottom)
    }
}

// MARK: - Blocks

struct ReportBlockView: View {
    let block: ReportBlock

    /// Money columns, sized so the widest realistic figure ("SGD 12,345.67")
    /// fits without shrinking.
    private let moneyColumn: CGFloat = 96
    /// Wide enough for the tracked "SHARE" / "COUNT" headings above them: a
    /// clipped column heading ("SHA…") reads as a rendering fault.
    private let shareColumn: CGFloat = 48
    private let countColumn: CGFloat = 44

    @ViewBuilder
    var body: some View {
        switch block {
        case .sectionHeader(let title, let note):
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.edEyebrow)
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(ReportInk.accent)
                if let note {
                    Text(note)
                        .font(.edCaption)
                        .foregroundStyle(ReportInk.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Rectangle()
                    .fill(ReportInk.ink)
                    .frame(height: 1)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Space.sm)

        case .caveat(let text):
            Text(text)
                .font(.edCaption)
                .foregroundStyle(ReportInk.muted)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .dayHeader(let title, let total, let continued):
            HStack(alignment: .firstTextBaseline) {
                Text(continued ? "\(title) (continued)" : title)
                    .font(.edFootnoteStrong)
                    .foregroundStyle(ReportInk.ink)
                Spacer()
                Text(total)
                    .font(.edFootnoteStrong)
                    .foregroundStyle(ReportInk.inkSoft)
            }
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(ReportInk.panel)

        case .ledgerRow(let row):
            ledgerRow(row)

        case .columnHeader(let columns):
            columnHeader(columns)

        case .participantRow(let row):
            HStack(spacing: 0) {
                Text(row.name)
                    .font(.edFootnote)
                    .foregroundStyle(ReportInk.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                money(row.paidText, color: ReportInk.inkSoft)
                money(row.spentText, color: ReportInk.inkSoft)
                money(row.netText, color: row.net > 0 ? ReportInk.credit : ReportInk.ink, strong: true)
            }
            .padding(.horizontal, Space.sm)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ReportInk.divider).frame(height: 1)
            }

        case .transferRow(let row):
            HStack(spacing: Space.sm) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ReportInk.accent)
                Text(row.sentence)
                    .font(.edFootnote)
                    .foregroundStyle(ReportInk.ink)
                Spacer()
                Text(row.amountText)
                    .font(.edFootnoteStrong)
                    .foregroundStyle(ReportInk.ink)
            }
            .padding(.horizontal, Space.sm)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ReportInk.divider).frame(height: 1)
            }

        case .categoryRow(let row):
            HStack(spacing: Space.sm) {
                Text(row.name)
                    .font(.edFootnote)
                    .foregroundStyle(ReportInk.ink)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ReportInk.accentSoft).frame(height: 6)
                        Capsule()
                            .fill(ReportInk.accent)
                            .frame(width: max(proxy.size.width * row.share, row.share > 0 ? 2 : 0), height: 6)
                    }
                    .frame(height: proxy.size.height, alignment: .center)
                }
                Text(row.shareText)
                    .font(.edCaption)
                    .foregroundStyle(ReportInk.muted)
                    .frame(width: shareColumn, alignment: .trailing)
                money(row.totalText, color: ReportInk.ink)
                Text("\(row.count)")
                    .font(.edCaption)
                    .foregroundStyle(ReportInk.muted)
                    .frame(width: countColumn, alignment: .trailing)
            }
            .padding(.horizontal, Space.sm)

        case .currencyRow(let row):
            HStack(spacing: Space.sm) {
                Text(row.code)
                    .font(.edFootnoteStrong)
                    .foregroundStyle(ReportInk.ink)
                    .frame(width: 70, alignment: .leading)
                Text(row.totalText)
                    .font(.edFootnote)
                    .foregroundStyle(ReportInk.inkSoft)
                    .frame(width: 120, alignment: .leading)
                Text(row.rateText)
                    .font(.edCaption)
                    .foregroundStyle(ReportInk.muted)
                Spacer()
            }
            .padding(.horizontal, Space.sm)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ReportInk.divider).frame(height: 1)
            }

        case .note(let text):
            Text(text)
                .font(.edFootnote)
                .foregroundStyle(ReportInk.muted)
                .padding(.horizontal, Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .gap:
            Color.clear
        }
    }

    private func ledgerRow(_ row: TripExpenseReport.LedgerRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(row.dateLabel)
                    .font(.edCaption)
                    .foregroundStyle(ReportInk.mutedSoft)
                    .frame(width: 44, alignment: .leading)
                Text(row.title)
                    .font(.edFootnote)
                    .foregroundStyle(ReportInk.ink)
                    .lineLimit(1)
                Spacer(minLength: Space.sm)
                if row.isRefund {
                    Text("REFUND")
                        .font(.system(size: 7, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(ReportInk.credit)
                }
                Text(row.amount)
                    .font(.edFootnoteStrong)
                    .foregroundStyle(row.isRefund ? ReportInk.credit : ReportInk.ink)
                    .frame(width: moneyColumn, alignment: .trailing)
            }
            HStack(spacing: Space.sm) {
                Spacer().frame(width: 44)
                Text("\(row.category) · \(row.payer) · \(row.split)")
                    .font(.edCaption)
                    .foregroundStyle(ReportInk.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ReportInk.divider).frame(height: 1)
        }
    }

    private func columnHeader(_ columns: ReportColumns) -> some View {
        let titles = columns.titles
        return HStack(spacing: columns == .participants ? 0 : Space.sm) {
            switch columns {
            case .participants:
                Text(titles[0]).frame(maxWidth: .infinity, alignment: .leading)
                Text(titles[1]).frame(width: moneyColumn, alignment: .trailing)
                Text(titles[2]).frame(width: moneyColumn, alignment: .trailing)
                Text(titles[3]).frame(width: moneyColumn, alignment: .trailing)
            case .categories:
                Text(titles[0]).frame(width: 130, alignment: .leading)
                Spacer()
                Text(titles[1]).frame(width: shareColumn, alignment: .trailing)
                Text(titles[2]).frame(width: moneyColumn, alignment: .trailing)
                Text(titles[3]).frame(width: countColumn, alignment: .trailing)
            case .currencies:
                Text(titles[0]).frame(width: 70, alignment: .leading)
                Text(titles[1]).frame(width: 120, alignment: .leading)
                Text(titles[2])
                Spacer()
            }
        }
        .font(.edEyebrow)
        .textCase(.uppercase)
        .tracking(1.0)
        .foregroundStyle(ReportInk.mutedSoft)
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func money(_ text: String, color: Color, strong: Bool = false) -> some View {
        Text(text)
            .font(strong ? .edFootnoteStrong : .edFootnote)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: moneyColumn, alignment: .trailing)
    }
}

import SwiftUI

/// The printed pages of the trip itinerary report (#532).
///
/// These views are never shown in the app. They exist to be handed to
/// `ImageRenderer`, one page at a time, so the export is real vector text in a
/// PDF rather than a screenshot.
///
/// The palette is the expense report's `ReportInk` with the Trips violet in
/// place of the Finance green: same paper, same ink, same reason for pinning
/// the light values as literals (a dark-mode export prints as a black
/// rectangle). The two typographic rules the expense report learned the hard
/// way hold here too, and for the same reason — a searchable PDF:
///
/// - **No `.monospacedDigit()`**, which on Inter substitutes a font whose
///   glyphs carry no usable Unicode mapping, so every time and date comes back
///   out of the PDF blank while rendering perfectly.
/// - **Eyebrow tracking stays at 1.2**, above which a text extractor reads the
///   letter gaps as word breaks and "DAY BY DAY" becomes unfindable.
///
/// A third one turned up here, and it is the same fault in a new place: Inter
/// renders `:` and `→` perfectly and embeds them with no usable Unicode
/// mapping, so "10:35 → 15:35" comes back out of the finished PDF as
/// "1035  1535". A time is the single most searched string in an itinerary, so
/// the three columns that carry one — the stop's time, a leg's times and route,
/// a stay's dates — print in the system font instead. Nothing else moves off
/// the ramp.
enum ItineraryInk {
    /// The Trips accent, which is the section this report belongs to.
    static let accent     = Color(hex: 0x6D28D9)
    static let accentSoft = Color(hex: 0xEDE6FB)

    /// Sized to sit level with the `.edFootnote` text beside it on each ramp.
    #if os(macOS)
    private static let timeSize: CGFloat = 11
    #else
    private static let timeSize: CGFloat = 13
    #endif

    /// For a time, a route or a date range: the punctuation in these has to
    /// survive text extraction, and Inter's does not.
    static let time       = Font.system(size: timeSize, weight: .semibold)
    static let timeLight  = Font.system(size: timeSize, weight: .regular)
}

// MARK: - Cover

struct ItineraryReportCoverPage: View {
    let cover: TripItineraryReport.Cover

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trip itinerary")
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(ItineraryInk.accent)

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

            // How long the trip is and how much is on it.
            HStack(alignment: .top, spacing: Space.lg) {
                headline(label: "Days", value: "\(cover.dayCount)", emphasis: true)
                headline(label: "Stops", value: "\(cover.stopCount)", emphasis: false)
            }

            Spacer().frame(height: Space.xl)

            if !cover.kindCounts.isEmpty { kindTable }

            Spacer().frame(height: Space.lg)

            VStack(alignment: .leading, spacing: Space.sm) {
                sentence(cover.scopeSentence)
                sentence(cover.timeSentence)
                if let omission = cover.omissionSentence {
                    sentence(omission)
                }
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

    /// What the trip is made of, before anyone turns the page.
    private var kindTable: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("What's on it")
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(ReportInk.muted)

            VStack(spacing: 0) {
                ForEach(cover.kindCounts) { row in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Image(systemName: row.icon)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(ItineraryInk.accent)
                            .frame(width: 16, alignment: .leading)
                        Text(row.label)
                            .font(.edBody)
                            .foregroundStyle(ReportInk.ink)
                            .lineLimit(1)
                        Spacer(minLength: Space.lg)
                        Text("\(row.count)")
                            .font(.edBodyMedium)
                            .foregroundStyle(ReportInk.inkSoft)
                    }
                    .padding(.vertical, 5)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(ReportInk.divider).frame(height: 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func sentence(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Circle()
                .fill(ItineraryInk.accent)
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

struct ItineraryReportContentPage: View {
    let blocks: [ItineraryReportBlock]
    /// Running head, so a page that arrives on its own still names the trip.
    let tripName: String
    let dateRange: String
    let pageNumber: Int
    let pageCount: Int

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    ItineraryReportBlockView(block: block)
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
                Text("\(tripName) · \(dateRange)")
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

struct ItineraryReportBlockView: View {
    let block: ItineraryReportBlock

    /// The time sits in its own column so the eye can run down the day. Wide
    /// enough for "10:35 → 15:35" and for "Check-out · 11:00".
    private let timeColumn: CGFloat = 104

    @ViewBuilder
    var body: some View {
        switch block {
        case .sectionHeader(let title, let note):
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.edEyebrow)
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(ItineraryInk.accent)
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

        case .dayHeader(let title, let subtitle, let continued):
            HStack(alignment: .firstTextBaseline) {
                Text(continued ? "\(title) (continued)" : title)
                    .font(.edFootnoteStrong)
                    .foregroundStyle(ReportInk.ink)
                    .lineLimit(1)
                Spacer()
                Text(subtitle)
                    .font(.edCaption)
                    .foregroundStyle(ReportInk.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(ReportInk.panel)

        case .stopRow(let row):
            stopRow(row)

        case .columnHeader(let columns):
            columnHeader(columns)

        case .stayRow(let row):
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(row.name)
                        .font(.edFootnote)
                        .foregroundStyle(ReportInk.ink)
                        .lineLimit(1)
                    Spacer(minLength: Space.sm)
                    Text(row.dates)
                        .font(ItineraryInk.timeLight)
                        .foregroundStyle(ReportInk.inkSoft)
                        .frame(width: 130, alignment: .trailing)
                    Text(row.nights)
                        .font(.edCaption)
                        .foregroundStyle(ReportInk.muted)
                        .frame(width: 64, alignment: .trailing)
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.edCaption)
                        .foregroundStyle(ReportInk.muted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ReportInk.divider).frame(height: 1)
            }

        case .travelRow(let row):
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(row.date)
                        .font(.edCaption)
                        .foregroundStyle(ReportInk.mutedSoft)
                        .frame(width: 48, alignment: .leading)
                    Text(row.mode)
                        .font(.edCaption)
                        .foregroundStyle(ReportInk.muted)
                        .frame(width: 64, alignment: .leading)
                    Text(row.route)
                        .font(ItineraryInk.timeLight)
                        .foregroundStyle(ReportInk.ink)
                        .lineLimit(1)
                    Spacer(minLength: Space.sm)
                    Text(row.times)
                        .font(ItineraryInk.timeLight)
                        .foregroundStyle(ReportInk.inkSoft)
                        .frame(width: 118, alignment: .trailing)
                }
                if !row.detail.isEmpty {
                    HStack(spacing: Space.sm) {
                        Spacer().frame(width: 112)
                        Text(row.detail)
                            .font(.edCaption)
                            .foregroundStyle(ReportInk.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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

    /// One stop: the time in its own column, then what it is, then everything
    /// the stop knows about itself on the lines beneath.
    private func stopRow(_ row: TripItineraryReport.StopRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(row.time)
                    .font(ItineraryInk.time)
                    .foregroundStyle(ReportInk.inkSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: timeColumn, alignment: .leading)
                Image(systemName: row.icon)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(ItineraryInk.accent)
                    .frame(width: 14, alignment: .leading)
                Text(row.title)
                    .font(.edFootnote)
                    .foregroundStyle(ReportInk.ink)
                    .lineLimit(1)
                Spacer(minLength: Space.sm)
                if row.isBooked {
                    Text("BOOKED")
                        .font(.system(size: 7, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(ItineraryInk.accent)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(ItineraryInk.accentSoft, in: Capsule(style: .continuous))
                }
                Text(row.kind)
                    .font(.edCaption)
                    .foregroundStyle(ReportInk.mutedSoft)
                    .lineLimit(1)
            }
            .frame(height: ItineraryReportBlock.stopBaseHeight, alignment: .center)

            ForEach(Array(row.details.enumerated()), id: \.offset) { _, line in
                HStack(spacing: Space.sm) {
                    Spacer().frame(width: timeColumn)
                    Text(line)
                        .font(.edCaption)
                        .foregroundStyle(ReportInk.muted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: ItineraryReportBlock.detailLineHeight, alignment: .center)
            }
        }
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ReportInk.divider).frame(height: 1)
        }
    }

    private func columnHeader(_ columns: ItineraryReportColumns) -> some View {
        let titles = columns.titles
        return HStack(spacing: Space.sm) {
            switch columns {
            case .stays:
                Text(titles[0])
                Spacer()
                Text(titles[1]).frame(width: 130, alignment: .trailing)
                Text(titles[2]).frame(width: 64, alignment: .trailing)
            case .travel:
                Text(titles[0]).frame(width: 48, alignment: .leading)
                Text(titles[1]).frame(width: 64, alignment: .leading)
                Text(titles[2])
                Spacer()
                Text(titles[3]).frame(width: 118, alignment: .trailing)
            }
        }
        .font(.edEyebrow)
        .textCase(.uppercase)
        .tracking(1.0)
        .foregroundStyle(ReportInk.mutedSoft)
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if os(iOS)
import SwiftUI
import PDFKit
import UIKit

/// Everything the scan surface needs to present a pass, as a value type.
///
/// Extracted from `TicketScanView` for #399 so one brightness-boosted surface can
/// serve both the itinerary (#222) and task tickets, rather than a second
/// near-identical 200-line view. The view knows nothing about where a pass came
/// from; the two `init`s below are the only places that know.
struct ScannablePass {
    /// Headline. For a boarding pass this already reads "6E681 · IXC→PNQ", so
    /// callers must not repeat the route in `subtitle`.
    let title: String
    /// One supporting line of facts, pre-joined. Empty to omit.
    let subtitle: String
    let payload: String
    let symbology: String
    let attachmentPath: String
    /// Printed under the barcode on the light panel. Empty to omit.
    let referenceUnderCode: String
    /// The one fact worth reaching for, boxed for prominence. Both nil to omit.
    let badgeLabel: String?
    let badgeValue: String?
    /// Section accent, so the surface reads as belonging to the feature it came
    /// from.
    let accent: Color

    /// A wide 1D/PDF417 code wants less height than a square QR/Aztec.
    var barcodeHeight: CGFloat {
        switch BarcodeSymbology(rawValue: symbology) ?? .other {
        case .qr, .aztec:       return 240
        case .pdf417, .code128: return 120
        case .other:            return 240
        }
    }

    var hasAttachment: Bool { !attachmentPath.isEmpty }
}

// MARK: - Itinerary pass (#222)

extension ScannablePass {
    /// Build a pass from an itinerary item. Preserves the original behaviour of
    /// this surface exactly: the route is never repeated in the subtitle, unknown
    /// gate/terminal are dropped rather than shown as junk, and a stay promotes
    /// its confirmation code to the badge (reception asks for it) while flights
    /// and events promote the seat (a gate agent asks for that).
    init(item: LocalItineraryItem) {
        let meta = item.ticketMeta
        let isStay = item.kindEnum == .stay
        let confirmation = item.sourceConfirmation.trimmingCharacters(in: .whitespaces)

        var parts: [String] = []
        if item.title != item.venue, !item.venue.isEmpty,
           meta?.originCode == nil, meta?.destinationCode == nil {
            parts.append(item.venue)
        }
        if let gate = TicketField.code(item.gate) { parts.append("Gate \(gate)") }
        if let terminal = TicketField.code(meta?.terminal) { parts.append("Terminal \(terminal)") }

        var badgeLabel: String?
        var badgeValue: String?
        if !item.seat.isEmpty {
            badgeLabel = "SEAT"
            badgeValue = item.seat
        } else if isStay, !confirmation.isEmpty {
            badgeLabel = "CONFIRMATION"
            badgeValue = confirmation
        }

        self.init(
            title: item.title,
            subtitle: parts.joined(separator: "  ·  "),
            payload: item.barcodePayload,
            symbology: item.barcodeSymbology,
            attachmentPath: item.attachmentPath,
            // A stay shows its confirmation in the badge below, so it isn't
            // repeated under the code.
            referenceUnderCode: isStay ? "" : confirmation,
            badgeLabel: badgeLabel,
            badgeValue: badgeValue,
            accent: Tokens.accent(for: .itineraries)
        )
    }
}

// MARK: - Wallet pass (#398)

extension ScannablePass {
    /// Build a pass from an already-projected wallet card.
    ///
    /// Takes `TicketCardData` rather than `LocalWalletCard` because the wallet's
    /// scan target carries the projection, not the model: the scan surface is
    /// display-only, and holding a value means it cannot be handed a row that has
    /// since been deleted. `TicketCardData` also spans both wallet sources, so a
    /// borrowed trip ticket reaches the scanner through this same init.
    ///
    /// The derivations mirror `init(item:)` deliberately — same subtitle rules,
    /// same seat-then-confirmation badge choice — so a ticket presents
    /// identically whether it is opened from a trip or from the wallet.
    init(card: TicketCardData) {
        let confirmation = card.sourceConfirmation.trimmingCharacters(in: .whitespaces)

        var parts: [String] = []
        if card.title != card.venue, !card.venue.isEmpty,
           card.meta?.originCode == nil, card.meta?.destinationCode == nil {
            parts.append(card.venue)
        }
        if let gate = TicketField.code(card.gate) { parts.append("Gate \(gate)") }
        if let terminal = TicketField.code(card.meta?.terminal) { parts.append("Terminal \(terminal)") }

        var badgeLabel: String?
        var badgeValue: String?
        if !card.seat.isEmpty {
            badgeLabel = "SEAT"
            badgeValue = card.seat
        } else if card.isStay, !confirmation.isEmpty {
            badgeLabel = "CONFIRMATION"
            badgeValue = confirmation
        }

        self.init(
            title: card.title,
            subtitle: parts.joined(separator: "  ·  "),
            payload: card.barcodePayload,
            symbology: card.barcodeSymbology,
            attachmentPath: card.attachmentPath,
            referenceUnderCode: card.isStay ? "" : confirmation,
            badgeLabel: badgeLabel,
            badgeValue: badgeValue,
            accent: Tokens.accent(for: .wallet)
        )
    }
}

// MARK: - Task pass (#399)

extension ScannablePass {
    /// Build a pass from a task ticket. `ownerTitle` backs the headline when the
    /// extractor could not read an event name off the ticket.
    init(ticket: TaskTicket, ownerTitle: String) {
        let meta = ticket.ticketMeta

        var parts: [String] = []
        if !ticket.venue.isEmpty { parts.append(ticket.venue) }
        // Date and printed time, the latter verbatim — never reformatted, because
        // it has to match what the gate is reading.
        if let date = ticket.eventDate {
            parts.append(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        }
        let time = ticket.startTimeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !time.isEmpty { parts.append(time) }
        if let gate = TicketField.code(ticket.gate) { parts.append("Gate \(gate)") }

        // Seat first, then section, then row: whichever exists is what a steward
        // will ask for.
        var badgeLabel: String?
        var badgeValue: String?
        if !ticket.seat.trimmingCharacters(in: .whitespaces).isEmpty {
            badgeLabel = "SEAT"
            badgeValue = ticket.seat
        } else if let section = meta?.section, !section.isEmpty {
            badgeLabel = "SECTION"
            badgeValue = section
        } else if let row = meta?.row, !row.isEmpty {
            badgeLabel = "ROW"
            badgeValue = row
        }

        self.init(
            title: ticket.displayTitle(fallback: ownerTitle),
            subtitle: parts.joined(separator: "  ·  "),
            payload: ticket.barcodePayload,
            symbology: ticket.barcodeSymbology,
            attachmentPath: ticket.attachmentPath,
            referenceUnderCode: ticket.reference,
            badgeLabel: badgeLabel,
            badgeValue: badgeValue,
            accent: Tokens.accent(for: .tasks)
        )
    }
}

/// Full-screen "present to scan" surface for a pass (#222, generalised in #399).
/// Optimised for a gate/turnstile scanner:
///  - The barcode is re-rendered LARGE on a forced-light panel (even in dark
///    mode) because scanners need high contrast.
///  - Screen brightness is saved and forced to max on appear, restored on
///    disappear.
///  - The idle timer is disabled while presented so the screen never dims
///    mid-queue.
///  - The original file is one tap away as a fallback when a scanner rejects
///    the regenerated code.
///
/// When the pass has no decodable barcode but does have an attachment, the
/// barcode panel shows the original (auto-cropped to the code when we can still
/// detect it — see `BarcodeImageView`).
///
/// iOS-only (issue #281): it depends on `UIScreen.brightness` and the idle
/// timer, which don't exist on macOS. Gate off the whole file; the shared
/// viewers it used (`TicketOriginalViewer`, `TicketAttachmentThumbnail`) now
/// live in the cross-platform `TicketViewers.swift`. This surface is NOT a
/// member of the macOS target and its call sites are `#if os(iOS)`-guarded.
struct TicketScanView: View {
    let pass: ScannablePass

    /// Convenience for the itinerary call sites, which pass an item.
    init(item: LocalItineraryItem) {
        self.pass = ScannablePass(item: item)
    }

    init(pass: ScannablePass) {
        self.pass = pass
    }

    @Environment(\.dismiss) private var dismiss
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness
    @State private var showingOriginal = false

    var body: some View {
        NavigationStack {
            ZStack {
                // A soft accent wash so the surface reads as a presentation
                // screen rather than a plain sheet.
                LinearGradient(
                    colors: [Tokens.ticketTintTop, Tokens.paper],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: Space.xl) {
                        barcodePanel
                        details
                        viewOriginalButton
                    }
                    .padding(Space.lg)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Scan ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
            }
        }
        .onAppear {
            // Save and max out brightness; keep the screen awake for scanning.
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1.0
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIScreen.main.brightness = savedBrightness
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(isPresented: $showingOriginal) {
            TicketOriginalViewer(attachmentPath: pass.attachmentPath)
        }
    }

    // MARK: - Barcode panel (forced light)

    private var barcodePanel: some View {
        VStack(spacing: Space.lg) {
            BarcodeImageView(
                payload: pass.payload,
                symbology: pass.symbology,
                attachmentPath: pass.attachmentPath,
                height: pass.barcodeHeight,
                compact: false,
                alignment: .center
            )
            .frame(maxWidth: .infinity)

            if !pass.referenceUnderCode.isEmpty {
                Text(pass.referenceUnderCode)
                    .font(.edMono)
                    .tracking(1.0)
                    .foregroundStyle(.black.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
        // Always light so a scanner gets maximum contrast, regardless of the
        // system appearance.
        .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Details

    private var details: some View {
        VStack(spacing: Space.md) {
            Text(pass.title)
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.center)

            if !pass.subtitle.isEmpty {
                Text(pass.subtitle)
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.muted)
                    .multilineTextAlignment(.center)
            }

            if let label = pass.badgeLabel, let value = pass.badgeValue {
                presentationBadge(label: label, value: value)
                    .padding(.top, Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The one fact worth reaching for, boxed for prominence: the seat at a
    /// gate, or the confirmation code at hotel reception. `minimumScaleFactor`
    /// keeps a long confirmation code on one line inside the badge.
    private func presentationBadge(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.edEyebrow)
                .tracking(1.4)
                .foregroundStyle(pass.accent)
            Text(value)
                .font(.edDisplay)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
        .background(
            pass.accent.opacity(0.10),
            in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(pass.accent.opacity(0.22), lineWidth: 0.5)
        )
    }

    // MARK: - View original

    @ViewBuilder
    private var viewOriginalButton: some View {
        if pass.hasAttachment {
            Button {
                Haptics.light()
                showingOriginal = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                    Text("View original ticket")
                        .font(.edBodyMedium)
                }
                .foregroundStyle(pass.accent)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
                .background(
                    pass.accent.opacity(0.12),
                    in: Capsule(style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View original ticket file")
        }
    }
}
#endif

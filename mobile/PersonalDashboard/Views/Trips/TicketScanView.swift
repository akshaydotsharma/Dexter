#if os(iOS)
import SwiftUI
import PDFKit
import UIKit

/// Full-screen "present to scan" surface for a ticket item (#222). Optimised
/// for a gate/turnstile scanner:
///  - The barcode is re-rendered LARGE on a forced-light panel (even in dark
///    mode) because scanners need high contrast.
///  - Screen brightness is saved and forced to max on appear, restored on
///    disappear.
///  - The idle timer is disabled while presented so the screen never dims
///    mid-queue.
///  - The original file is one tap away as a fallback when a scanner rejects
///    the regenerated code.
///
/// When the item has no decodable barcode but does have an attachment, the
/// barcode panel shows the original (auto-cropped to the code when we can still
/// detect it — see `BarcodeImageView`).
///
/// iOS-only (issue #281): it depends on `UIScreen.brightness` and the idle
/// timer, which don't exist on macOS. Gate off the whole file; the shared
/// viewers it used (`TicketOriginalViewer`, `TicketAttachmentThumbnail`) now
/// live in the cross-platform `TicketViewers.swift`. This surface is NOT a
/// member of the macOS target and its call sites are `#if os(iOS)`-guarded.
struct TicketScanView: View {
    let item: LocalItineraryItem

    @Environment(\.dismiss) private var dismiss
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness
    @State private var showingOriginal = false

    private var meta: TicketMeta? { item.ticketMeta }

    var body: some View {
        NavigationStack {
            ZStack {
                // A soft itinerary-accent wash so the surface reads as a
                // presentation screen rather than a plain sheet.
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
            TicketOriginalViewer(attachmentPath: item.attachmentPath)
        }
    }

    // MARK: - Barcode panel (forced light)

    private var barcodePanel: some View {
        VStack(spacing: Space.lg) {
            BarcodeImageView(
                payload: item.barcodePayload,
                symbology: item.barcodeSymbology,
                attachmentPath: item.attachmentPath,
                height: barcodeHeight,
                compact: false,
                alignment: .center
            )
            .frame(maxWidth: .infinity)

            // A stay surfaces its confirmation in the prominent badge below the
            // barcode (see `details`), so we don't repeat it on the scan panel.
            // Flights / events keep the reference printed under the code.
            if !item.sourceConfirmation.isEmpty && !isStay {
                Text(item.sourceConfirmation)
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

    /// A wide 1D/PDF417 code wants less height than a square QR/Aztec.
    private var barcodeHeight: CGFloat {
        switch BarcodeSymbology(rawValue: item.barcodeSymbology) ?? .other {
        case .qr, .aztec:      return 240
        case .pdf417, .code128: return 120
        case .other:           return 240
        }
    }

    // MARK: - Details

    private var details: some View {
        VStack(spacing: Space.md) {
            // Headline: flight + route (boarding pass) or the event title. The
            // title already reads "6E681 · IXC→PNQ", so we do NOT repeat the
            // route on a second line below.
            Text(item.title)
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.center)

            let line = detailLine
            if !line.isEmpty {
                Text(line)
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.muted)
                    .multilineTextAlignment(.center)
            }

            // Seat gets prominence at a gate; for a stay, the confirmation code
            // does (reception asks for it). Same badge treatment for both.
            if !item.seat.isEmpty {
                presentationBadge(label: "SEAT", value: item.seat)
                    .padding(.top, Space.xs)
            } else if isStay, !stayConfirmation.isEmpty {
                presentationBadge(label: "CONFIRMATION", value: stayConfirmation)
                    .padding(.top, Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var isStay: Bool { item.kindEnum == .stay }

    private var stayConfirmation: String {
        item.sourceConfirmation.trimmingCharacters(in: .whitespaces)
    }

    /// The one fact worth reaching for, boxed for prominence: the seat at a
    /// gate, or the confirmation code at hotel reception. `minimumScaleFactor`
    /// keeps a long confirmation code on one line inside the badge.
    private func presentationBadge(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.edEyebrow)
                .tracking(1.4)
                .foregroundStyle(Tokens.accent(for: .itineraries))
            Text(value)
                .font(.edDisplay)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
        .background(
            Tokens.accent(for: .itineraries).opacity(0.10),
            in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(Tokens.accent(for: .itineraries).opacity(0.22), lineWidth: 0.5)
        )
    }

    /// A single supporting line of the facts that survive sanitization. The
    /// route is NOT repeated here (it's in the headline), and unknown
    /// gate/terminal are dropped entirely rather than shown as junk.
    private var detailLine: String {
        var parts: [String] = []
        if item.title != item.venue, !item.venue.isEmpty,
           meta?.originCode == nil, meta?.destinationCode == nil {
            parts.append(item.venue)
        }
        if let gate = TicketField.code(item.gate) { parts.append("Gate \(gate)") }
        if let terminal = TicketField.code(meta?.terminal) { parts.append("Terminal \(terminal)") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - View original

    @ViewBuilder
    private var viewOriginalButton: some View {
        if !item.attachmentPath.isEmpty {
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
                .foregroundStyle(Tokens.accent(for: .itineraries))
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
                .background(
                    Tokens.accent(for: .itineraries).opacity(0.12),
                    in: Capsule(style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View original ticket file")
        }
    }
}
#endif

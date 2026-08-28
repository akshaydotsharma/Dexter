import SwiftUI

/// One attachment, as a plain row (#466).
///
/// This replaces `TaskTicketCardView`, which drew every attachment as a
/// wallet-style pass. The card was only ever right for a credential you hold up
/// at a gate, and the Wallet already decides which documents are that and draws
/// them itself. Everywhere else the pass face was decoration wrapped around a
/// file: a restaurant menu and a receipt got the tint, the perforation and the
/// stub exactly as readily as a boarding pass did.
///
/// So this row deliberately references no `Tokens.ticket*` token, no
/// `PerforatedDivider` and no barcode. That is the mechanical test for "this is
/// not a card". What a person needs from a list of attachments is which file it
/// is and a way in, which is a thumbnail, a name, a kind and a chevron.
///
/// Display-only. The tap, the context menu and the accessibility label are
/// attached by the parent, because they differ between a document the list owns
/// and one that belongs to the record itself.
struct TaskAttachmentRow: View {
    let title: String
    /// Kind first, then one fact that helps tell two files apart. Built by
    /// `subtitle(for:)` for a stored document; supplied directly for a record's
    /// own attachment.
    let subtitle: String
    let attachmentPath: String
    /// The owning section's colour, so a stop's boarding pass does not draw in
    /// the Tasks indigo.
    var accent: Color = Tokens.accent(for: .tasks)

    var body: some View {
        HStack(spacing: Space.md) {
            TicketAttachmentThumbnail(relativePath: attachmentPath, accent: accent)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.sm)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.mutedSoft)
        }
        .padding(Space.md)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }
}

extension TaskAttachmentRow {
    /// The second line for a stored document: what kind of file it is, then one
    /// fact that separates two of the same kind.
    ///
    /// The missing-file case wins outright and says so in words. It is the state
    /// `TaskTicketCardView` used to spell out below its tear, and it matters
    /// more than the kind does: the row synced across from another device but
    /// its bytes did not, and an unexplained placeholder reads as a bug rather
    /// than as a file that is simply elsewhere.
    static func subtitle(for ticket: TaskTicket, fileIsPresent: Bool) -> String {
        guard fileIsPresent else { return "The file is on your other device" }

        var parts = [kindWord(for: ticket.attachmentPath)]
        if let date = ticket.eventDate {
            parts.append(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        } else {
            let venue = ticket.venue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !venue.isEmpty { parts.append(venue) }
        }
        return parts.joined(separator: " · ")
    }

    /// A `.pkpass` is checked first because it is also not a PDF and not an
    /// image, so every other order lands it in the wrong bucket.
    static func kindWord(for attachmentPath: String) -> String {
        if attachmentPath.trimmingCharacters(in: .whitespaces).isEmpty { return "Barcode only" }
        if TicketStorage.isPass(attachmentPath) { return "Pass" }
        if TicketStorage.isPDF(attachmentPath) { return "PDF" }
        return "Image"
    }
}

/// An attachment stored on the owning record itself rather than as a document of
/// its own (#466).
///
/// A trip stop has two independent stores: the file scanned onto the stop lives
/// on `LocalItineraryItem.attachmentPath`, and anything attached afterwards is a
/// `LocalTaskTicket` row. Before #466 the first was reachable only through the
/// boarding-pass card on the timeline, so removing that card would have left it
/// with no way in at all.
///
/// Rather than mint a fake `LocalTaskTicket` for it, which would offer Save,
/// Remove and a Wallet toggle against a row that does not exist, it is carried
/// through the list as this read-only value. Removing a stop's own ticket clears
/// eight fields on the stop rather than deleting one file, so that action stays
/// where it already lives, in the stop's editor.
struct OwnerAttachment: Identifiable {
    /// The relative path is unique per record, and a record cannot hold two.
    var id: String { attachmentPath }
    let attachmentPath: String
    let title: String
    let subtitle: String
}

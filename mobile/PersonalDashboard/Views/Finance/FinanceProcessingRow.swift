import SwiftUI

/// A transient, in-memory job shown as a "Processing…" row at the top of the
/// Finance list while a capture (receipt) or statement import runs in the
/// background (#186). It is UI-only — nothing is persisted to `LocalExpense`
/// for the pending state. Multiple jobs can be in flight at once (two uploads
/// in a row → two rows), so `FinanceView` holds these in an array keyed by `id`.
struct ProcessingJob: Identifiable, Equatable {
    enum Kind: Equatable {
        case receipt
        case statement

        /// Label shown on the row while the job runs. Mirrors the copy the
        /// old blocking overlays used so the language stays familiar.
        var label: String {
            switch self {
            case .receipt:   return "Reading receipt…"
            case .statement: return "Importing statement…"
            }
        }

        /// SF Symbol shown in the leading badge, matching each channel's
        /// menu icon so the row reads as "the thing I just picked".
        var sfSymbol: String {
            switch self {
            case .receipt:   return "doc.text.viewfinder"
            case .statement: return "doc.text.magnifyingglass"
            }
        }
    }

    let id: UUID
    let kind: Kind

    /// Optional per-instance label that overrides `kind.label`. Used to show
    /// the picked file name in the statement banner, e.g. "Importing
    /// Citi_May2026.pdf…" (#189). nil falls back to the kind's generic copy.
    let overrideLabel: String?

    /// The label actually rendered on the row: the override when present,
    /// otherwise the kind's generic copy.
    var displayLabel: String { overrideLabel ?? kind.label }

    init(kind: Kind, overrideLabel: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.overrideLabel = overrideLabel
    }
}

/// Non-blocking "Processing…" status banner shown between the date-filter
/// chips and the search field (#186 follow-up). Deliberately styled AWAY
/// from `ExpenseRow`'s elevated card treatment — a flat, inline banner on
/// `Tokens.surface2` with no border and a compact spinner, so it reads as
/// system status ("something is happening"), never as a transaction the
/// list is about to fill in. Multiple concurrent jobs stack in a tight
/// VStack from the caller.
struct FinanceProcessingRow: View {
    let job: ProcessingJob

    var body: some View {
        HStack(spacing: Space.sm) {
            ProgressView()
                .controlSize(.small)
                .tint(Tokens.accentFinance)

            Image(systemName: job.kind.sfSymbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Tokens.accentFinance)

            Text(job.displayLabel)
                .font(.edFootnote)
                .foregroundStyle(Tokens.inkSoft)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.displayLabel) Working in the background.")
    }
}

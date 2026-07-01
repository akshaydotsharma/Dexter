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

    init(kind: Kind) {
        self.id = UUID()
        self.kind = kind
    }
}

/// Non-blocking "Processing…" row pinned above the day-grouped expense list.
/// Same card shape / border as `ExpenseRow`, with a spinner where the amount
/// would sit, so an in-flight job reads as a placeholder expense the list is
/// about to fill in.
struct FinanceProcessingRow: View {
    let job: ProcessingJob

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: job.kind.sfSymbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Tokens.accentFinance)
                .frame(width: 36, height: 36)
                .background(Tokens.paper2, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(job.kind.label)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                Text("Working in the background")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
            }

            Spacer()

            ProgressView()
                .tint(Tokens.accentFinance)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm + 2)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .paperBorder(Tokens.border, radius: 26)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(job.kind.label)
    }
}

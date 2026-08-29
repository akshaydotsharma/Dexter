import SwiftUI

/// Non-blocking status banner for a capture or statement import (#186), now
/// driven by `ImportJobCenter` rather than by view state (#498).
///
/// Deliberately styled AWAY from `ExpenseRow`'s elevated card treatment: a
/// flat, inline banner on `Tokens.surface2` with no border, so it reads as
/// system status ("something is happening"), never as a transaction the list
/// is about to fill in. Multiple concurrent jobs stack in a tight VStack from
/// the caller.
///
/// Three states, because a job now outlives the screen that started it:
///   - running: spinner, plus "3 of 5" once the extractor knows how many
///     chunks there are, plus a cancel button.
///   - finished with a summary: tap to read it, which dismisses the row.
///   - finished with a failure: the same, in the danger tint.
struct FinanceProcessingRow: View {
    let job: ImportJob
    /// Called when the user taps a FINISHED row. The caller shows the outcome
    /// and then acknowledges the job, which removes it.
    var onOpen: () -> Void = {}
    /// Called when the user cancels a RUNNING row.
    var onCancel: () -> Void = {}

    var body: some View {
        if job.isFinished {
            Button(action: onOpen) { content }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityText)
                .accessibilityHint("Shows what was imported, then dismisses this row.")
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText)
        }
    }

    private var content: some View {
        HStack(spacing: Space.sm) {
            leadingBadge

            Text(job.displayLabel)
                .font(.edFootnote)
                .foregroundStyle(Tokens.inkSoft)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Space.xs)

            trailingControl
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    @ViewBuilder
    private var leadingBadge: some View {
        switch job.outcome {
        case .none:
            ProgressView()
                .controlSize(.small)
                .tint(Tokens.accentFinance)

            Image(systemName: job.kind.sfSymbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Tokens.accentFinance)
        case .summary:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Tokens.success)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Tokens.danger)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if job.isFinished {
            // The row is the button; this is only the affordance.
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.muted)
        } else {
            if let progress = job.progressLabel {
                Text(progress)
                    .font(.edFootnote)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.muted)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.muted)
                    .padding(Space.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop this import")
        }
    }

    private var accessibilityText: String {
        switch job.outcome {
        case .none:
            let progress = job.progressLabel.map { ", part \($0)" } ?? ""
            return "\(job.displayLabel)\(progress). Working in the background."
        case .summary:
            return "\(job.displayLabel). Finished. Tap to see what was imported."
        case .failure:
            return "\(job.displayLabel). Failed. Tap to see why."
        }
    }
}

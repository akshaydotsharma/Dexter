import SwiftUI

/// A small state pill: suspect, needs detail, possible duplicate, confidence
/// (#543).
///
/// One component for all four so they share a height and a corner and cannot
/// drift apart as more are added.
struct MealFlagChip: View {
    let text: String
    let systemImage: String?
    let tint: Color

    init(_ text: String, systemImage: String? = nil, tint: Color = Tokens.muted) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.edCaption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 3)
        .background(tint.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// One logged meal in the day's list (#543).
///
/// The row carries the description, the time, the calories, and whatever is
/// wrong with it. Nothing else: the per-item breakdown and the other seven
/// nutrients live in the detail sheet, because a list that showed eight numbers
/// per row would make the day unreadable at exactly the moment there was enough
/// in it to be worth reading.
struct MealRow: View {
    let meal: LocalMeal

    /// Derived on every read from the day's rows rather than stored, so
    /// deleting one half of a pair clears the flag on the other.
    let isDuplicate: Bool

    let onTap: () -> Void

    private var needsAttention: Bool {
        meal.isSuspect || meal.needsDetail || isDuplicate
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: meal.mealTypeEnum.sfSymbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(needsAttention ? Tokens.warning : Tokens.accentMeals)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(meal.mealDescription)
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: Space.sm) {
                        Text(Self.timeFormatter.string(from: meal.loggedAt))
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                            .monospacedDigit()
                        Text(meal.mealTypeEnum.displayName)
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                    }

                    if !chips.isEmpty {
                        // Wraps rather than clipping: on a phone three chips do
                        // not fit one line beside the calorie column.
                        WrappingChipRow(chips: chips)
                    }

                    if let reason = meal.suspectReason {
                        Text(reason)
                            .font(.edCaption)
                            .foregroundStyle(Tokens.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let note = meal.assumptionsNote {
                        // One muted line, and only when there is no warning to
                        // show in the same slot. This is where a clamped value
                        // is surfaced: a repaired meal is NOT suspect, so it has
                        // no `suspectReason`, and the repair sentence is written
                        // to the front of this note for exactly that reason.
                        Text(note)
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: Space.sm)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(meal.needsDetail ? "—" : MealFormat.calories(meal.calories))
                        .font(.edBodyMedium)
                        .foregroundStyle(meal.isSuspect || meal.needsDetail ? Tokens.muted : Tokens.ink)
                        .monospacedDigit()
                    Text("kcal")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                }
            }
            .padding(.vertical, Space.md)
            .padding(.horizontal, Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                needsAttention ? Tokens.warningSoft.opacity(0.45) : Tokens.surface,
                in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            )
            .paperBorder(needsAttention ? Tokens.warning.opacity(0.35) : Tokens.border, radius: Radius.lg)
            .contentShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the meal to correct or repeat it")
    }

    private var chips: [MealFlagChip] {
        var out: [MealFlagChip] = []
        if meal.needsDetail {
            out.append(MealFlagChip("Needs detail", systemImage: "questionmark.circle", tint: Tokens.warning))
        }
        if meal.isSuspect {
            out.append(MealFlagChip("Check this", systemImage: "exclamationmark.triangle", tint: Tokens.danger))
        }
        if isDuplicate {
            out.append(MealFlagChip("Possible duplicate", systemImage: "doc.on.doc", tint: Tokens.info))
        }
        if !meal.needsDetail {
            out.append(
                MealFlagChip(
                    MealFormat.confidenceBand(meal.confidence),
                    tint: meal.totalsWereOverridden ? Tokens.success : Tokens.muted
                )
            )
        }
        return out
    }

    private var accessibilityText: String {
        var parts = [meal.mealTypeEnum.displayName, meal.mealDescription]
        if meal.needsDetail {
            parts.append("needs detail, no numbers yet")
        } else {
            parts.append("\(MealFormat.calories(meal.calories)) kilocalories")
        }
        if meal.isSuspect, let reason = meal.suspectReason { parts.append(reason) }
        if isDuplicate { parts.append("possible duplicate") }
        return parts.joined(separator: ", ")
    }

    /// Times read in the device zone: `loggedAt` is a true instant, unlike the
    /// meal's day, which is a UTC anchor and must never reach a device-local
    /// formatter (#506).
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

/// Chips laid out left to right, wrapping when they run out of width (#543).
///
/// A `Layout` rather than a nest of `HStack`s guessing at a break point: three
/// chips plus a calorie column do not fit one line on a phone, and the set of
/// chips is data-dependent, so where the line breaks cannot be decided here.
struct WrappingChipRow: View {
    let chips: [MealFlagChip]

    var body: some View {
        ChipFlowLayout {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                chip
            }
        }
    }
}

/// The flow itself. Measures each child at its natural size, wraps when the next
/// one would cross the right edge.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

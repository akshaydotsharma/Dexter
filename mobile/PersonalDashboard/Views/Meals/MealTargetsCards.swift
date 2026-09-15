import SwiftUI

/// The card pinned above Today when no targets exist (#544).
///
/// ### Why it is a card and not an empty state
///
/// Logging is never blocked on setup. The day card below this one already adds
/// up, and a meal logged before targets are set counts exactly as much as one
/// logged after. So this cannot be a wall; it has to be an offer sitting above
/// a surface that already works.
///
/// ### No hue
///
/// On this surface hue means verdict and nothing else. A tinted setup card
/// would be the only coloured thing on a screen where colour is a reading about
/// the day, which is the one association the section cannot afford to blur.
struct MealTargetsSetupCard: View {
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Targets").eyebrow()

            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Set your daily targets")
                    .font(.edHeading)
                    .foregroundStyle(Tokens.ink)
                // The sentence the user has to read before acting, so it sits
                // at the reading rung rather than as a footnote.
                Text("Six questions about your body and your goal, and Dexter works out the eight numbers a day is read against. You can change any of them before anything is saved.")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.sm) {
                Button("Set targets", action: onStart)
                    .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                Spacer(minLength: Space.sm)
                Text("One request. Nothing is stored until you save.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }
}

/// The row that replaces the setup card once targets exist (#544).
///
/// Quiet on purpose. The numbers themselves are already on the day card two
/// blocks up, drawn as bars against the day; repeating them here at any size
/// would put the same fact on screen twice and make the second one look like a
/// different fact. So this states only what the day card cannot: what the
/// targets were derived FOR, and when.
struct MealTargetsRow: View {
    let targets: MealTargets
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily targets")
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                    Text(subtitle)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.md)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Tokens.mutedSoft)
            }
            .padding(Space.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
        .accessibilityLabel("Daily targets, \(subtitle)")
    }

    private var subtitle: String {
        var parts: [String] = []
        if let goal = MealGoal(rawValue: targets.goal) {
            parts.append(goal.displayName)
        }
        if let level = ActivityLevel(rawValue: targets.activityLevel) {
            parts.append(level.displayName.lowercased())
        }
        if targets.weightKg > 0 {
            parts.append("\(String(format: "%.0f", targets.weightKg.rounded())) kg")
        }
        let edited = targets.handEdited.count
        if edited > 0 {
            parts.append(edited == 1 ? "1 changed by you" : "\(edited) changed by you")
        }
        let head = parts.isEmpty ? "Derived from your body and goal" : parts.joined(separator: " · ")
        return "\(head). Set \(Self.dayFormatter.string(from: targets.updatedAt))."
    }

    /// `updatedAt` is a real instant rather than a stored day anchor, so a
    /// device-local formatter is correct here.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()
}

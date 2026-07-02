import SwiftUI

/// Small inline badge shown on an expense row (and reused in pickers) for a
/// Person or Event tag (#183). A tinted capsule with an SF Symbol + label,
/// sized to sit quietly on the row's secondary line.
struct PersonEventBadge: View {
    enum Kind {
        case person
        case event

        var symbol: String {
            switch self {
            case .person: return "person.fill"
            case .event:  return "calendar"
            }
        }
    }

    let kind: Kind
    let label: String
    /// Tint colour. People carry a per-record colour; events use a fixed
    /// finance-adjacent accent.
    var tint: Color = Tokens.accentFinance

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: kind.symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.edCaption)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .accessibilityLabel("\(kind == .person ? "Person" : "Event"): \(label)")
    }
}

extension Color {
    /// Parse a hex string like "10B981" or "#10B981" into a Color. Falls back
    /// to the finance accent when the string can't be parsed, so a bad value
    /// never crashes a chip. Reuses the `Color(hex: UInt32)` initialiser.
    init(personHex hexString: String) {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        if let value = UInt32(cleaned, radix: 16), cleaned.count == 6 {
            self = Color(hex: value)
        } else {
            self = Tokens.accentFinance
        }
    }
}

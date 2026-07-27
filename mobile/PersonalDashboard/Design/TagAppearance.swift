import SwiftUI

/// Colour identity for task tags (issue #338).
///
/// Every tag pill used to render in the same neutral grey, so a screen of
/// tagged tasks carried no colour information at all. Each tag now gets a
/// colour, derived from its own name, and the user can override it.
///
/// Two properties matter and neither is free:
///
/// The default has to be STABLE. Swift's `hashValue` is seeded per process, so
/// a tag would change colour on every launch. The hash below is FNV-1a over the
/// normalised name, computed the same way on every device and every run.
///
/// The default has to be the SAME everywhere the tag appears. That falls out of
/// deriving it from the name rather than from position in a list, which would
/// shift the moment a tag was added or removed.
///
/// Colours come from `ListAppearance.palette` — the existing eight Tokens
/// accents, each carrying a light and a dark variant, so nothing new is
/// hardcoded and pills stay readable in both themes.
enum TagAppearance {

    /// The shared eight. Same set the list-appearance picker offers, so the two
    /// features cannot drift apart.
    static var palette: [ListAppearance.PaletteColor] { ListAppearance.palette }

    /// Tags are matched case- and whitespace-insensitively, so "Work", "work"
    /// and " work " are one tag with one colour.
    static func normalized(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// FNV-1a (32-bit) over the normalised name. Deterministic across launches
    /// and devices, which `String.hashValue` is not.
    private static func stableHash(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    /// The colour a tag gets when the user hasn't chosen one.
    static func defaultPaletteColor(for tag: String) -> ListAppearance.PaletteColor {
        let key = normalized(tag)
        guard !key.isEmpty else { return ListAppearance.defaultPaletteColor }
        let index = Int(stableHash(key) % UInt32(palette.count))
        return palette[index]
    }

    /// The colour in effect: the user's choice when there is one, else the
    /// derived default.
    static func paletteColor(for tag: String) -> ListAppearance.PaletteColor {
        if let id = TagColorStore.shared.colorID(for: tag),
           let match = palette.first(where: { $0.id == id }) {
            return match
        }
        return defaultPaletteColor(for: tag)
    }

    static func color(for tag: String) -> Color {
        paletteColor(for: tag).color
    }
}

/// Per-tag colour overrides, persisted in `UserDefaults`.
///
/// `@Observable` rather than a bare defaults read so a colour picked in the
/// task editor repaints the pills behind it immediately: SwiftUI registers the
/// dependency when a body reads `colorID(for:)`, even through this singleton.
///
/// UserDefaults, not SwiftData: this is a display preference over a free-text
/// string, it has no relationships, and adding a model would mean a schema
/// migration on installs that already hold every user's data (see the
/// migration warnings in CLAUDE.md) for something a dictionary covers.
@Observable
final class TagColorStore {
    static let shared = TagColorStore()

    private static let defaultsKey = "tagColorOverrides"

    /// normalised tag name → `ListAppearance.PaletteColor.id`.
    private(set) var overrides: [String: String]

    private init() {
        overrides = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
    }

    func colorID(for tag: String) -> String? {
        let key = TagAppearance.normalized(tag)
        guard !key.isEmpty else { return nil }
        return overrides[key]
    }

    /// Set (or clear, with nil) the colour for a tag.
    func setColorID(_ id: String?, for tag: String) {
        let key = TagAppearance.normalized(tag)
        guard !key.isEmpty else { return }
        if let id { overrides[key] = id } else { overrides.removeValue(forKey: key) }
        UserDefaults.standard.set(overrides, forKey: Self.defaultsKey)
    }
}

// MARK: - Pill

/// The one tag pill. Tinted fill, tinted text, hairline in the same hue, so a
/// row of tags reads as a set rather than as eight unrelated buttons.
struct TagPill: View {
    let tag: String
    /// Row pills are caption-sized; the editor's chips are larger and set their
    /// own metrics, so only the compact form lives here.
    var font: Font = .edCaption

    var body: some View {
        let tint = TagAppearance.color(for: tag)
        Text(tag)
            .font(font)
            .foregroundStyle(tint)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5))
    }
}

// MARK: - Colour picker

/// Eight swatches for choosing a tag's colour. Shown under the tag chips in the
/// task editor once a tag is selected, so the control only appears when there
/// is something for it to act on.
struct TagColorPicker: View {
    /// The tag being recoloured. Empty renders nothing.
    let tag: String

    var body: some View {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let current = TagAppearance.paletteColor(for: trimmed)
            HStack(spacing: Space.sm) {
                Text("Colour")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                ForEach(TagAppearance.palette) { entry in
                    Button {
                        TagColorStore.shared.setColorID(entry.id, for: trimmed)
                    } label: {
                        Circle()
                            .fill(entry.color)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .stroke(Tokens.ink, lineWidth: entry.id == current.id ? 2 : 0)
                                    .padding(-3)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(entry.name)
                    .accessibilityLabel("\(entry.name) for tag \(trimmed)")
                    .accessibilityAddTraits(entry.id == current.id ? [.isSelected, .isButton] : .isButton)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

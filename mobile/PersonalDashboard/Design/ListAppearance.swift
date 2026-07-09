import SwiftUI
import UIKit

/// Single source of truth for a list's visual identity (#253): the curated SF
/// Symbol set, the palette, the default fallback, and the local keyword→icon
/// mapper. Every list's icon + color resolves through here, so a nil / unknown
/// value always renders as a valid, on-brand tile instead of a blank chip.
///
/// Colors are sourced from the existing `Tokens` accent palette — the stored
/// `colorHex` is the palette KEY (the light-mode hex, uppercased, no prefix),
/// which resolves back to a light/dark `Color.paper(...)` pair so tiles stay
/// correct in both themes. Storing a bare hex would lose the dark variant.
enum ListAppearance {

    // MARK: - Palette

    struct PaletteColor: Identifiable, Hashable {
        /// Stable key AND the canonical stored `colorHex` (light hex, uppercased).
        let id: String
        let name: String
        let light: UInt32
        let dark: UInt32
        var color: Color { Color.paper(light, dark) }
    }

    /// Eight colors, all lifted from the existing `Tokens` section accents so
    /// the feature introduces no new hardcoded colors outside this helper.
    static let palette: [PaletteColor] = [
        PaletteColor(id: "0F766E", name: "Teal",   light: 0x0F766E, dark: 0x2DD4BF), // accentLists
        PaletteColor(id: "4338CA", name: "Indigo", light: 0x4338CA, dark: 0x818CF8), // accentTasks
        PaletteColor(id: "6D28D9", name: "Purple", light: 0x6D28D9, dark: 0xA78BFA), // accentItineraries
        PaletteColor(id: "B91C1C", name: "Red",    light: 0xB91C1C, dark: 0xF87171), // accentToday
        PaletteColor(id: "B45309", name: "Amber",  light: 0xB45309, dark: 0xF59E0B), // accentNotes
        PaletteColor(id: "047857", name: "Green",  light: 0x047857, dark: 0x10B981), // accentFinance
        PaletteColor(id: "7C3F58", name: "Pink",   light: 0x7C3F58, dark: 0xE5A3BA), // accentActivity
        PaletteColor(id: "475569", name: "Slate",  light: 0x475569, dark: 0x94A3B8)  // accentSettings
    ]

    /// Teal — matches the historical `Tokens.accentLists`, so every existing
    /// (nil-color) list keeps the exact look it has today.
    static let defaultColorHex = "0F766E"
    /// `checklist` exists on iOS 16+ so it is safe on the iOS 17 baseline.
    static let defaultIcon = "checklist"

    static var defaultPaletteColor: PaletteColor {
        palette.first { $0.id == defaultColorHex } ?? palette[0]
    }

    /// Strict match: returns the palette entry for a stored hex OR a color name
    /// (case-insensitive), or nil when nothing matches. Callers that want a
    /// guaranteed color use `color(forHex:)`; the AI executor uses this to
    /// distinguish "model gave a valid color" from "fall back to keyword map".
    static func matchedPaletteColor(_ raw: String?) -> PaletteColor? {
        guard let raw else { return nil }
        let norm = normalizeHex(raw)
        if let byHex = palette.first(where: { $0.id == norm }) { return byHex }
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return palette.first { $0.name.lowercased() == lower }
    }

    /// Always returns a usable color: the matched palette color or the default.
    static func color(forHex hex: String?) -> Color {
        (matchedPaletteColor(hex) ?? defaultPaletteColor).color
    }

    private static func normalizeHex(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.hasPrefix("0X") { s.removeFirst(2) }
        return s
    }

    // MARK: - Icons

    struct IconGroup: Identifiable {
        let id: String        // group / theme name
        let symbols: [String]
    }

    /// ~38 curated SF Symbols grouped by theme. Every symbol is available on the
    /// iOS 17 baseline. The properties-sheet grid renders these groups directly.
    static let iconGroups: [IconGroup] = [
        IconGroup(id: "General",  symbols: ["checklist", "list.bullet", "star", "flag", "bookmark", "pin"]),
        IconGroup(id: "Shopping", symbols: ["cart", "bag", "gift", "creditcard"]),
        IconGroup(id: "Travel",   symbols: ["airplane", "suitcase", "map", "beach.umbrella", "car", "tram"]),
        IconGroup(id: "Work",     symbols: ["briefcase", "laptopcomputer", "calendar", "chart.bar", "folder"]),
        IconGroup(id: "Health",   symbols: ["figure.run", "dumbbell", "heart", "leaf", "cross.case"]),
        IconGroup(id: "Home",     symbols: ["house", "fork.knife", "cup.and.saucer", "wrench.and.screwdriver"]),
        IconGroup(id: "Learning", symbols: ["book", "graduationcap", "lightbulb", "pencil"]),
        IconGroup(id: "Fun",      symbols: ["gamecontroller", "music.note", "film", "camera"])
    ]

    /// Flat list of every curated symbol (used for validation / highlighting).
    static let allIcons: [String] = iconGroups.flatMap { $0.symbols }

    /// Returns a guaranteed-renderable symbol name: the stored value when it is
    /// a real SF Symbol, otherwise the default. Guards against an AI-supplied
    /// symbol name that doesn't exist on the device (blank-tile prevention).
    static func resolvedIconName(_ stored: String?) -> String {
        guard let stored, !stored.isEmpty,
              UIImage(systemName: stored) != nil else { return defaultIcon }
        return stored
    }

    /// Whether a symbol name renders on this device.
    static func isValidSymbol(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return UIImage(systemName: name) != nil
    }

    // MARK: - Keyword → appearance mapper

    private struct KeywordRule {
        let keywords: [String]
        let icon: String
        let colorHex: String
    }

    /// Simple lowercased-substring rules, checked top to bottom. No API calls —
    /// runs instantly on the device when the user creates a list without picking
    /// an icon, or when the AI omits icon/color on `draft_list`.
    private static let keywordRules: [KeywordRule] = [
        .init(keywords: ["grocer", "supermarket", "fairprice", "pantry"], icon: "cart", colorHex: "047857"),
        .init(keywords: ["shop", "buy", "purchase", "wishlist"], icon: "bag", colorHex: "047857"),
        .init(keywords: ["gym", "workout", "exercise", "fitness", "run", "training", "lift"], icon: "figure.run", colorHex: "B91C1C"),
        .init(keywords: ["trip", "travel", "flight", "vacation", "holiday", "itinerary"], icon: "airplane", colorHex: "4338CA"),
        .init(keywords: ["pack", "packing", "luggage"], icon: "suitcase", colorHex: "4338CA"),
        .init(keywords: ["read", "book", "reading", "novel"], icon: "book", colorHex: "B45309"),
        .init(keywords: ["study", "learn", "course", "school", "class", "exam"], icon: "graduationcap", colorHex: "B45309"),
        .init(keywords: ["work", "project", "office", "meeting", "deadline", "sprint"], icon: "briefcase", colorHex: "475569"),
        .init(keywords: ["money", "budget", "finance", "bill", "expense", "savings"], icon: "creditcard", colorHex: "047857"),
        .init(keywords: ["food", "recipe", "cook", "dinner", "meal", "restaurant", "menu"], icon: "fork.knife", colorHex: "B45309"),
        .init(keywords: ["home", "house", "chore", "clean", "move", "moving", "apartment"], icon: "house", colorHex: "6D28D9"),
        .init(keywords: ["gift", "present", "birthday", "christmas", "holiday gift"], icon: "gift", colorHex: "7C3F58"),
        .init(keywords: ["health", "doctor", "medicine", "wellness", "medical"], icon: "heart", colorHex: "B91C1C"),
        .init(keywords: ["music", "playlist", "song", "album"], icon: "music.note", colorHex: "6D28D9"),
        .init(keywords: ["movie", "film", "watch", "show", "series"], icon: "film", colorHex: "4338CA"),
        .init(keywords: ["game", "gaming", "play"], icon: "gamecontroller", colorHex: "6D28D9"),
        .init(keywords: ["idea", "goal", "plan", "brainstorm"], icon: "lightbulb", colorHex: "B45309"),
        .init(keywords: ["garden", "plant", "grow"], icon: "leaf", colorHex: "047857")
    ]

    /// Infer an icon + palette color from a list title. Falls back to the
    /// default checklist + teal when no keyword matches.
    static func infer(from title: String) -> (icon: String, colorHex: String) {
        let t = title.lowercased()
        for rule in keywordRules where rule.keywords.contains(where: { t.contains($0) }) {
            return (rule.icon, rule.colorHex)
        }
        return (defaultIcon, defaultColorHex)
    }
}

// MARK: - Checklist convenience accessors

extension Checklist {
    /// The guaranteed-renderable SF Symbol for this list.
    var resolvedIcon: String { ListAppearance.resolvedIconName(iconName) }
    /// The theme-adaptive color for this list (palette match or default teal).
    var resolvedColor: Color { ListAppearance.color(forHex: colorHex) }
}

// MARK: - Reusable icon chip

/// The rounded colored square that carries a list's icon. Solid fill + white
/// glyph for maximum at-a-glance differentiation against the paper surface,
/// matching Apple Reminders' density. Shared by the Lists tile and Today row.
struct ListIconChip: View {
    let icon: String
    let color: Color
    var size: CGFloat = 40
    var corner: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

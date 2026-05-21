import SwiftUI
import UIKit

// MARK: - Section identity

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case chat
    case today
    case tasks
    case notes
    case lists
    case dashboard
    case activity
    case itineraries
    case vocabulary
    case settings
    case helpCenter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chat:        return "Chat"
        case .today:       return "Today"
        case .tasks:       return "Tasks"
        case .notes:       return "Notes"
        case .lists:       return "Lists"
        case .dashboard:   return "Dashboard"
        case .activity:    return "Activity"
        case .itineraries: return "Itineraries"
        case .vocabulary:  return "Vocabulary"
        case .settings:    return "Settings"
        case .helpCenter:  return "Help center"
        }
    }

    /// SF Symbol used in the side drawer and bottom tab bar.
    var icon: String {
        switch self {
        case .chat:        return "sparkles"
        case .today:       return "calendar"
        case .tasks:       return "checkmark.square"
        case .notes:       return "doc.text"
        case .lists:       return "list.bullet"
        case .dashboard:   return "rectangle.grid.2x2"
        case .activity:    return "clock.arrow.circlepath"
        case .itineraries: return "airplane"
        case .vocabulary:  return "character.book.closed"
        case .settings:    return "gearshape"
        case .helpCenter:  return "questionmark.circle"
        }
    }
}

// MARK: - Hex helper

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >>  8) & 0xFF) / 255
        let b = Double( hex        & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// Light/dark pair. Resolved at render time via the system color scheme.
    static func paper(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? dark : light))
        })
    }
}

// MARK: - Editorial Calm tokens

enum Tokens {
    // Neutral spine
    static let paper        = Color.paper(0xFBF9F4, 0x14110D)
    static let paper2       = Color.paper(0xF4F0E6, 0x1B1813)
    static let surface      = Color.paper(0xFFFFFF, 0x1F1C16)
    static let surface2     = Color.paper(0xF8F5EE, 0x25211A)
    static let border       = Color.paper(0xE8E2D2, 0x36302A)
    static let borderStrong = Color.paper(0xD9D2BE, 0x4A4338)
    static let divider      = Color.paper(0xEFE9DA, 0x2A2620)
    static let ink          = Color.paper(0x1F1B16, 0xF2EBDA)
    static let inkSoft      = Color.paper(0x4A4339, 0xDCD3BE)
    static let muted        = Color.paper(0x7B7263, 0xA89E8A)
    static let mutedSoft    = Color.paper(0xA89E8A, 0x756B5B)

    // Section accents
    static let accentChat      = Color.paper(0x1F1B16, 0xF2EBDA)
    static let accentToday     = Color.paper(0xB91C1C, 0xF87171)
    static let accentTasks     = Color.paper(0x4338CA, 0x818CF8)
    static let accentNotes     = Color.paper(0xB45309, 0xF59E0B)
    static let accentLists     = Color.paper(0x0F766E, 0x2DD4BF)
    static let accentDashboard = Color.paper(0x1F1B16, 0xF2EBDA)
    static let accentActivity  = Color.paper(0x7C3F58, 0xE5A3BA)
    static let accentVocabulary = Color.paper(0x57534E, 0xB7B0A2)
    static let accentItineraries = Color.paper(0x6D28D9, 0xA78BFA)
    static let accentSettings  = Color.paper(0x475569, 0x94A3B8)
    static let accentHelp      = Color.paper(0x475569, 0x94A3B8)
    static let accentFg        = Color.paper(0xFFFFFF, 0x14110D)

    // Semantics
    static let success      = Color.paper(0x15803D, 0x4ADE80)
    static let successSoft  = Color.paper(0xDCFCE7, 0x052E16)
    static let warning      = Color.paper(0xB45309, 0xF59E0B)
    static let warningSoft  = Color.paper(0xFEF3C7, 0x422006)
    static let danger       = Color.paper(0xB91C1C, 0xF87171)
    static let dangerSoft   = Color.paper(0xFEE2E2, 0x450A0A)
    static let info         = Color.paper(0x0E7490, 0x22D3EE)

    static func accent(for section: AppSection) -> Color {
        switch section {
        case .chat:        return accentChat
        case .today:       return accentToday
        case .tasks:       return accentTasks
        case .notes:       return accentNotes
        case .lists:       return accentLists
        case .dashboard:   return accentDashboard
        case .activity:    return accentActivity
        case .itineraries: return accentItineraries
        case .vocabulary:  return accentVocabulary
        case .settings:    return accentSettings
        case .helpCenter:  return accentHelp
        }
    }
}

// MARK: - Active section environment

private struct ActiveSectionKey: EnvironmentKey {
    static let defaultValue: AppSection = .chat
}

extension EnvironmentValues {
    var activeSection: AppSection {
        get { self[ActiveSectionKey.self] }
        set { self[ActiveSectionKey.self] = newValue }
    }
}

extension View {
    /// Wrap any subtree with the active section. The subtree reads
    /// `@Environment(\.activeSection)` and pulls the right accent.
    func activeSection(_ section: AppSection) -> some View {
        environment(\.activeSection, section)
    }
}

import SwiftUI

enum ColorSchemePref: String, CaseIterable {
    case system, light, dark

    var resolved: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Cycle: system → light → dark → system.
    var next: ColorSchemePref {
        switch self {
        case .system: return .light
        case .light:  return .dark
        case .dark:   return .system
        }
    }
}

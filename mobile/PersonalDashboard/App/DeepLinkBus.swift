import Foundation
import SwiftUI

/// Single point of contact between deep-link sources (URL scheme, App
/// Intents) and the app's router. Both `DexterDeepLink.handle(_:router:)`
/// and `OpenDexterIntent.perform()` write into this bus; the root view
/// observes it and drains the pending payload into `AppRouter`.
///
/// Using a singleton ObservableObject (instead of e.g. NotificationCenter)
/// keeps the contract typed and lets SwiftUI rerender naturally on
/// `.onChange(of:)`.
@MainActor
final class DeepLinkBus: ObservableObject {
    static let shared = DeepLinkBus()

    enum Pending: Equatable {
        case focus(sectionRaw: String, id: UUID?)
        case activity
    }

    @Published var pending: Pending?

    private init() {}
}

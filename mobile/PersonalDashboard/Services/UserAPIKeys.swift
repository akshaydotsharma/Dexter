import Foundation

/// API keys the USER supplies at runtime, held in the Keychain (issue #337).
///
/// The build-time sources — the `ANTHROPIC_API_KEY` env var xcodegen bakes into
/// the scheme, and the Info.plist value `ship-lan.sh` injects at archive time —
/// are both properties of the BUILD, not of the install. On macOS that is the
/// whole problem: `xcodegen generate` without the variable exported writes the
/// literal `${ANTHROPIC_API_KEY}` into the scheme, `AppConfig.resolved` rejects
/// it, and Chat reports "not configured" until someone remembers the export.
/// Regenerating the project is a routine step here, so the working state was
/// one command away from being lost at all times.
///
/// A key stored here survives regeneration, rebuilds, and reinstalls, and it
/// takes precedence over both build-time sources so a user-entered value always
/// wins. Clearing it falls back to whatever the build carries.
///
/// Deliberately un-cached: `AppConfig.anthropicAPIKey` is read a handful of
/// times per request, a Keychain lookup is microseconds, and a static mutable
/// cache would be a data race across the background tasks that call it.
enum UserAPIKeys {

    // MARK: - Anthropic

    /// The user-supplied Anthropic key, or nil when none is stored.
    static var anthropic: String? {
        guard let value = KeychainStore.get(account: KeychainStore.Account.anthropicAPIKey) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Store (non-empty) or clear (empty / nil) the Anthropic key.
    /// Returns false when the Keychain write itself failed.
    @discardableResult
    static func setAnthropic(_ value: String?) -> Bool {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return KeychainStore.delete(account: KeychainStore.Account.anthropicAPIKey)
        }
        return KeychainStore.set(trimmed, account: KeychainStore.Account.anthropicAPIKey)
    }

    // MARK: - Display

    /// Where the key currently in effect came from. Drives the Settings status
    /// line, so a build that already carries a key doesn't nag for one.
    enum Source {
        /// Entered by the user, held in the Keychain.
        case keychain
        /// Baked in at build time (scheme env var or Info.plist).
        case build
        /// No usable key anywhere; AI features will refuse.
        case none

        var label: String {
            switch self {
            case .keychain: return "Stored on this device"
            case .build:    return "Provided by this build"
            case .none:     return "Not configured"
            }
        }
    }

    static var anthropicSource: Source {
        if anthropic != nil { return .keychain }
        return AppConfig.buildTimeAnthropicKey != nil ? .build : .none
    }

    /// `sk-ant…AB12` — enough to tell two keys apart, not enough to use one.
    /// Never log or display the whole value.
    static func masked(_ key: String) -> String {
        guard key.count > 10 else { return String(repeating: "•", count: max(key.count, 4)) }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }
}

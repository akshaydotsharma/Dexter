import Foundation

/// Connection settings + credentials for the receipts IMAP inbox (#143).
///
/// The host and account email are not secret and live in UserDefaults so the
/// Settings UI can show them without a Keychain round-trip. The app password
/// is secret and lives ONLY in the Keychain (`KeychainStore`). Nothing here
/// ever prints the password.
struct EmailInboxCredentials: Equatable, Sendable {
    var host: String
    var port: Int
    var email: String

    /// Sensible defaults for the locked decision: dexter.receipts@gmail.com
    /// over Gmail IMAP TLS.
    static let defaultHost = "imap.gmail.com"
    static let defaultPort = 993
    static let defaultEmail = "dexter.receipts@gmail.com"

    static var `default`: EmailInboxCredentials {
        EmailInboxCredentials(host: defaultHost, port: defaultPort, email: defaultEmail)
    }
}

/// Reads/writes the non-secret inbox config (host/port/email) in UserDefaults
/// and the secret app password in the Keychain. The on/off state of the whole
/// ingestion feature is also stored here.
enum EmailInboxConfig {

    private enum Keys {
        static let host = "email_inbox.host"
        static let port = "email_inbox.port"
        static let email = "email_inbox.email"
        static let enabled = "email_inbox.enabled"
    }

    private static var defaults: UserDefaults { .standard }

    // MARK: - Connection settings (non-secret)

    static var settings: EmailInboxCredentials {
        get {
            let host = defaults.string(forKey: Keys.host) ?? EmailInboxCredentials.defaultHost
            let storedPort = defaults.integer(forKey: Keys.port)
            let port = storedPort > 0 ? storedPort : EmailInboxCredentials.defaultPort
            let email = defaults.string(forKey: Keys.email) ?? EmailInboxCredentials.defaultEmail
            return EmailInboxCredentials(host: host, port: port, email: email)
        }
        set {
            defaults.set(newValue.host, forKey: Keys.host)
            defaults.set(newValue.port, forKey: Keys.port)
            defaults.set(newValue.email, forKey: Keys.email)
        }
    }

    // MARK: - App password (secret, Keychain)

    /// Whether an app password is stored. Never returns the value itself.
    static var hasPassword: Bool {
        KeychainStore.has(account: KeychainStore.Account.imapAppPassword)
    }

    /// Read the app password for use by the IMAP client. Returns nil when
    /// unset. Callers must not log the result.
    static func readPassword() -> String? {
        KeychainStore.get(account: KeychainStore.Account.imapAppPassword)
    }

    /// Persist the app password to the Keychain. Pass empty string to clear.
    @discardableResult
    static func setPassword(_ password: String) -> Bool {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return KeychainStore.delete(account: KeychainStore.Account.imapAppPassword)
        }
        return KeychainStore.set(trimmed, account: KeychainStore.Account.imapAppPassword)
    }

    // MARK: - Feature toggle

    /// Whether the user has switched the ingestion on. Defaults to false so
    /// nothing fetches until the user has entered credentials and opted in.
    static var isEnabled: Bool {
        get { defaults.bool(forKey: Keys.enabled) }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    /// The feature can actually run only when it's enabled, has a password,
    /// and has a non-empty host/email.
    static var isReady: Bool {
        let s = settings
        return isEnabled && hasPassword && !s.host.isEmpty && !s.email.isEmpty
    }
}

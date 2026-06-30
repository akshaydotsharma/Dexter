import Foundation
import Security

/// Thin wrapper over the iOS Keychain for storing a single secret value
/// per account under one service namespace. Used by the email-to-itinerary
/// ingestion (#143) to hold the Gmail IMAP app password, which must never
/// touch UserDefaults, source, or logs.
///
/// Generic-password items keyed by (service, account). Values round-trip as
/// UTF-8 data. Reads/writes are synchronous and cheap; callers run them off
/// any hot path anyway.
enum KeychainStore {

    /// Service namespace for all Dexter keychain items. Keeps our items from
    /// colliding with anything else and makes a wipe-all trivial.
    static let service = "com.akshaysharma.personaldashboard.keychain"

    /// Stable account keys for the values we persist.
    enum Account {
        /// Gmail IMAP app password for the receipts inbox.
        static let imapAppPassword = "imap.app_password"
    }

    // MARK: - API

    /// Store (or replace) a string value for an account. Empty string is a
    /// valid value (it overwrites); use `delete` to remove entirely.
    /// `accessibleAfterFirstUnlock` is required so background fetch can read
    /// the password while the device is locked.
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first so we don't have to branch on
        // add-vs-update and risk a duplicate-item error.
        delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Read the string value for an account, or nil if absent / unreadable.
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// True when a non-empty value exists for the account.
    static func has(account: String) -> Bool {
        guard let value = get(account: account) else { return false }
        return !value.isEmpty
    }

    /// Remove the item for an account. No-op (returns true) if it wasn't there.
    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

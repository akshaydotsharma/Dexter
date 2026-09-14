import Foundation

/// Single source of truth for the Finance display-currency preference.
///
/// Finance stores every expense in SGD (the canonical base — see
/// `LocalExpense.sgdAmount`). This facade governs the currency finances are
/// *displayed* in: a display-only conversion applied at format time, never a
/// re-computation of stored values.
///
/// Backed by `UserDefaults` so both SwiftUI (`@AppStorage`, keyed by the same
/// strings) and non-View formatters read and write the same values. The View
/// owns the live binding on `displayCurrencyCode`; `FXService` writes the
/// cached `displayRateToSGD` factor; the money formatter reads both
/// synchronously at render time.
///
/// Mirrors the `BackupSettings` pattern (typed accessors over a `Key`
/// namespace of raw UserDefaults strings).
enum FinanceSettings {
    enum Key {
        /// ISO 4217 code the user wants finances displayed in. Default "SGD".
        static let displayCurrencyCode = "finance.displayCurrencyCode"
        /// Cached FX factor: SGD per 1 unit of the display currency, i.e.
        /// "1 display unit = N SGD" (same orientation as `LocalFXRate.rateToSGD`).
        /// Default 1.0 (SGD passthrough). `displayValue = sgdValue / factor`.
        static let displayRateToSGD = "finance.displayRateToSGD"
        /// What the user is called wherever their own name sits beside other
        /// people's (#530). Default "You".
        static let userDisplayName = "finance.userDisplayName"
    }

    private static var defaults: UserDefaults { .standard }

    // MARK: - Typed accessors

    /// The display currency. Defaults to "SGD" so a fresh install (and every
    /// surface before the user picks anything) behaves exactly as before.
    static var displayCurrencyCode: String {
        get { defaults.string(forKey: Key.displayCurrencyCode) ?? "SGD" }
        set { defaults.set(newValue, forKey: Key.displayCurrencyCode) }
    }

    /// Cached "1 display unit = N SGD" factor, written by
    /// `FXService.refreshDisplayRate()`. Defaults to 1.0 so, absent a warmed
    /// rate, the formatter falls back to SGD passthrough rather than a bad
    /// conversion. Never persisted as 0/NaN (the writer guards against it).
    static var displayRateToSGD: Double {
        get {
            // `double(forKey:)` returns 0 for an unset key; treat that as the
            // 1.0 default so an un-warmed factor never divides to infinity.
            let stored = defaults.double(forKey: Key.displayRateToSGD)
            return stored > 0 ? stored : 1.0
        }
        set { defaults.set(newValue, forKey: Key.displayRateToSGD) }
    }

    /// What to call the user wherever their own label sits beside other
    /// people's: the split avatars, a settle-up line, the payer picker, the
    /// trip participant row, the exported report (#530).
    ///
    /// DISPLAY ONLY. The user is not a `LocalPerson` and must never become
    /// one: `nil` is the person id that means "the user" in every
    /// `ExpenseSplitEntry`, in `paidByPersonUUID`, in `LocalExpense.myShareSGD`
    /// and in `TripSettlement`. This renames the label and touches no row.
    ///
    /// Empty or whitespace reads as "You", so clearing the Settings field is
    /// how you go back rather than a state with no name at all.
    static var userDisplayName: String {
        get {
            let stored = (defaults.string(forKey: Key.userDisplayName) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stored.isEmpty ? defaultUserDisplayName : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed, forKey: Key.userDisplayName)
        }
    }

    /// The second-person default. Compared against by the grammar helpers, so
    /// it is a constant rather than a literal repeated at each call site.
    static let defaultUserDisplayName = "You"

    /// True while the user has not named themselves, i.e. the label is still
    /// the pronoun "You". The surfaces that pick between second and third
    /// person ("You owe" vs "Akshay owes") branch on this, NOT on the party:
    /// the party is always the user, it is the WORD that changes the grammar.
    static var userIsAddressedInSecondPerson: Bool {
        userDisplayName == defaultUserDisplayName
    }

    /// Avatar initial for the user. "Y" until they name themselves.
    static var userDisplayInitial: String {
        String(userDisplayName.prefix(1)).uppercased()
    }

    // MARK: - Derived

    /// True when the display currency is the SGD base — the formatter's
    /// fast path (no conversion, original "SGD " symbol styling).
    static var isDisplaySGD: Bool {
        displayCurrencyCode.uppercased() == "SGD"
    }
}

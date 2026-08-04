import Foundation

/// Shared, reused `NumberFormatter` / `DateFormatter` instances for the Finance
/// surfaces (#442).
///
/// Every money and date string on a Finance screen used to allocate and
/// configure a brand new formatter. That reads as harmless until you count the
/// calls: one expense row asks for 2 to 3 money strings, and a full-year list is
/// ~1,520 rows, so a single paint churned through several thousand
/// `NumberFormatter` instances. Formatter construction is one of the more
/// expensive things in Foundation, and it was happening on the main thread
/// inside `body`.
///
/// Caching is keyed on the exact configuration, so a cached instance is only
/// ever handed out for the settings it was built with. Instances are configured
/// once at insert and never mutated afterwards, which is the condition under
/// which `NumberFormatter` and `DateFormatter` are safe to format with from more
/// than one thread (`FXService` formats off the main actor).
enum FinanceFormatters {
    private static let lock = NSLock()
    private static var numberCache: [String: NumberFormatter] = [:]
    private static var dateCache: [String: DateFormatter] = [:]

    /// Currency formatter whose symbol is the ISO code plus a space, e.g.
    /// "SGD 1,247.50". Matches the styling every Finance surface already used.
    static func currency(code: String, fractionDigits: Int) -> NumberFormatter {
        cachedNumberFormatter(key: "c|\(code)|\(fractionDigits)") { formatter in
            formatter.numberStyle = .currency
            formatter.currencyCode = code
            formatter.maximumFractionDigits = fractionDigits
            formatter.minimumFractionDigits = fractionDigits
            formatter.currencySymbol = "\(code) "
        }
    }

    /// Plain grouped decimal, e.g. "1,247.50". Used for the original-currency
    /// sub-label on an expense row, which prefixes the code itself.
    static func decimal(fractionDigits: Int) -> NumberFormatter {
        cachedNumberFormatter(key: "d|\(fractionDigits)") { formatter in
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = fractionDigits
            formatter.minimumFractionDigits = fractionDigits
        }
    }

    /// Date formatter for a fixed `dateFormat` pattern.
    static func date(format: String) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let cached = dateCache[format] { return cached }
        let formatter = DateFormatter()
        formatter.dateFormat = format
        dateCache[format] = formatter
        return formatter
    }

    private static func cachedNumberFormatter(
        key: String,
        configure: (NumberFormatter) -> Void
    ) -> NumberFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let cached = numberCache[key] { return cached }
        let formatter = NumberFormatter()
        configure(formatter)
        numberCache[key] = formatter
        return formatter
    }
}

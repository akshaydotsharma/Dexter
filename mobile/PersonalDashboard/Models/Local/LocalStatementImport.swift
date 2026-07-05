import Foundation
import SwiftData

/// One permanent record of a credit-card / bank statement PDF that was run
/// through `StatementImporter` (#234). Gives the "Parsed Files & Imports"
/// history a durable row per import, mirroring how `LocalEmailIngestLog`
/// records each forwarded email. Before this model, a statement import's
/// counts were shown once in an alert and then discarded.
///
/// Additive-only model — new @Model class, no field ever removed, so it is
/// safe to add to the schema on existing installs (lightweight migration).
@Model
final class LocalStatementImport {
    @Attribute(.unique) var clientUUID: UUID

    /// The imported PDF's file name, e.g. "Citi_May2026.pdf". May be empty when
    /// the picker gave no name.
    var fileName: String

    /// Parsed statement attribution label, e.g. "May 2026 Citi - 1234". Empty
    /// when the header couldn't be read.
    var statementLabel: String

    /// Count buckets, mirroring `StatementImportResult`. `imported` counts every
    /// row that produced a `LocalExpense` this run (spend + refund);
    /// `refunds` is the refund subset.
    var imported: Int
    var skippedDuplicates: Int
    var ignoredNonSpend: Int
    var failed: Int
    var refunds: Int

    /// Bank-statement deposit lines (money received) counted this import but
    /// never stored as expenses (income isn't tracked yet, #243). Additive
    /// field with a default so the SwiftData migration stays lightweight on
    /// existing installs (ADD only, never remove).
    var deposits: Int = 0

    /// True when the model likely ran out of output budget on a very large
    /// statement, so some tail rows may be missing.
    var possiblyTruncated: Bool

    /// Comma-joined `LocalExpense.clientUUID` strings inserted by this import,
    /// so the detail screen can resolve and show exactly those expenses. Mirrors
    /// the `LocalEmailIngestLog.addedItemUUIDs` pattern. Additive field with a
    /// default so the migration stays lightweight. Empty when nothing landed.
    var importedExpenseUUIDs: String = ""

    var createdAt: Date

    init(
        clientUUID: UUID = UUID(),
        fileName: String,
        statementLabel: String,
        imported: Int,
        skippedDuplicates: Int,
        ignoredNonSpend: Int,
        failed: Int,
        refunds: Int,
        possiblyTruncated: Bool,
        importedExpenseUUIDs: [UUID] = [],
        deposits: Int = 0,
        createdAt: Date = Date()
    ) {
        self.clientUUID = clientUUID
        self.fileName = fileName
        self.statementLabel = statementLabel
        self.imported = imported
        self.skippedDuplicates = skippedDuplicates
        self.ignoredNonSpend = ignoredNonSpend
        self.failed = failed
        self.refunds = refunds
        self.deposits = deposits
        self.possiblyTruncated = possiblyTruncated
        self.importedExpenseUUIDs = importedExpenseUUIDs
            .map { $0.uuidString.lowercased() }
            .joined(separator: ",")
        self.createdAt = createdAt
    }

    /// Parsed list of imported-expense UUIDs (as lowercased strings, matching
    /// `LocalExpense.clientUUID` which is stored as a String).
    var importedExpenseUUIDStrings: [String] {
        importedExpenseUUIDs
            .split(separator: ",")
            .map { String($0) }
            .filter { !$0.isEmpty }
    }
}

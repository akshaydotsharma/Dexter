import Foundation
import SwiftData

/// Coordinates one full email-to-itinerary fetch cycle (#143):
///  1. Read credentials (Keychain + UserDefaults).
///  2. Connect to IMAP, SELECT INBOX, SEARCH all UIDs.
///  3. For each UID not already in the idempotency ledger: FETCH, parse,
///     run the on-device matcher, record the outcome, post a notification,
///     mark the message \Seen, and write the processed-message ledger row.
///  4. Trim the ingest log to a bounded recent window.
///
/// Idempotency is enforced BEFORE any mutation: the processed-message ledger
/// is keyed by Message-Id (or uidvalidity:uid), and we skip any message whose
/// key already exists. We only write the ledger row AFTER a successful
/// outcome, inside the same flow, so a crash mid-process re-processes the
/// message next time rather than silently dropping it.
@MainActor
struct EmailIngestService {

    let store: SwiftDataStore

    init(store: SwiftDataStore = .shared) {
        self.store = store
    }

    /// Run a fetch cycle. Returns the number of messages added / skipped /
    /// failed in this run (for the caller's logging / background-task result).
    ///
    /// When `ignoreProcessed` is true, the idempotency ledger is bypassed for
    /// THIS run so already-fetched messages re-run through parsing + matching
    /// (the "Re-scan (ignore processed)" action, #143). The ledger rows for
    /// the re-run messages are also cleared so a subsequent normal cycle won't
    /// see stale entries. Idempotency for normal cycles is unaffected.
    @discardableResult
    func runFetchCycle(ignoreProcessed: Bool = false) async -> (added: Int, updated: Int, skipped: Int, failed: Int) {
        guard EmailInboxConfig.isReady else {
            return (0, 0, 0, 0)
        }
        guard let password = EmailInboxConfig.readPassword(), !password.isEmpty else {
            return (0, 0, 0, 0)
        }

        let settings = EmailInboxConfig.settings
        let client = IMAPClient(config: .init(
            host: settings.host,
            port: settings.port,
            email: settings.email,
            appPassword: password
        ))

        var counts = (added: 0, updated: 0, skipped: 0, failed: 0)

        do {
            try await client.connectAndLogin()
            try await client.selectInbox()
            let uidValidity = await client.uidValidity
            let uids = try await client.searchAllUIDs()

            // Newest first so the freshest bookings are handled first under any
            // background-time budget. Bound the per-cycle work.
            let ordered = uids.sorted(by: >).prefix(25)

            for uid in ordered {
                // Cheap pre-check on the uidvalidity:uid composite key. The
                // real Message-Id check happens after fetch (we can't know it
                // until we read headers), but this avoids re-fetching bodies
                // for messages we already handled.
                let compositeKey = "uidvalidity:\(uidValidity):\(uid)"
                if !ignoreProcessed, isProcessed(key: compositeKey) { continue }

                do {
                    let raw = try await client.fetchMessage(uid: uid)
                    let message = EmailMessage.parse(raw.rawSource)
                    let stableKey = message.stableKey ?? compositeKey

                    if ignoreProcessed {
                        // Re-scan: clear any prior ledger rows for this message
                        // so the re-run is clean and a later normal cycle won't
                        // trip over a stale entry.
                        clearProcessed(key: compositeKey)
                        clearProcessed(key: stableKey)
                    } else if isProcessed(key: stableKey) {
                        // Already done under its Message-Id; record the
                        // composite key too so we don't re-fetch next time.
                        recordProcessed(key: compositeKey, uid: uid, uidValidity: uidValidity)
                        continue
                    }

                    let result = try await EmailToItinerary.default().run(
                        message: message,
                        timezone: TimeZone.current.identifier,
                        // Reconcile-update existing items ONLY on the explicit
                        // Re-scan; the automatic cycle keeps add-missing-only.
                        reconcile: ignoreProcessed
                    )

                    writeLog(message: message, result: result)

                    switch result.outcome {
                    case .added:
                        // `.added` covers adds and/or reconcile-updates (#165).
                        // Split the counters so the summary can report both.
                        if !result.addedItemUUIDs.isEmpty {
                            counts.added += 1
                        }
                        if !result.updatedItemUUIDs.isEmpty {
                            counts.updated += 1
                        }
                        // An expense-only add (#177) has neither item list
                        // populated; count it as an add so the run is never
                        // silently uncounted.
                        if result.addedItemUUIDs.isEmpty && result.updatedItemUUIDs.isEmpty {
                            counts.added += 1
                        }
                    case .skipped:
                        counts.skipped += 1
                    case .failed:
                        counts.failed += 1
                    }

                    // Mark processed under BOTH keys so neither a Message-Id
                    // re-index nor a UID reuse re-runs it.
                    recordProcessed(key: stableKey, uid: uid, uidValidity: uidValidity)
                    if stableKey != compositeKey {
                        recordProcessed(key: compositeKey, uid: uid, uidValidity: uidValidity)
                    }

                    // Best-effort: drop it out of the unread list.
                    try? await client.markSeen(uid: uid)
                } catch {
                    // A single message failing (fetch error, LLM error) should
                    // not abort the cycle or mark the message processed — it
                    // gets retried next time. Write a visible failure row so a
                    // fetch/parse exception isn't invisible, then keep going.
                    NSLog("EmailIngestService: message uid %d failed: %@", uid, error.localizedDescription)
                    writeFailureLog(uid: uid, error: error)
                    counts.failed += 1
                }
            }

            await client.logoutAndClose()
        } catch {
            // Connection / login / select failure: nothing processed.
            NSLog("EmailIngestService: cycle failed: %@", error.localizedDescription)
            await client.logoutAndClose()
            return counts
        }

        trimLog()
        return counts
    }

    // MARK: - Undo

    /// Undo a previous "added" ingest: delete the exact items recorded in the
    /// log entry, then mark the entry as undone. Returns the trip name for the
    /// confirmation notification, or nil if nothing to undo.
    @discardableResult
    func undo(logUUID: UUID) -> String? {
        let key = logUUID
        guard let entry = try? store.context.fetch(
            FetchDescriptor<LocalEmailIngestLog>(predicate: #Predicate { $0.clientUUID == key })
        ).first else {
            return nil
        }
        guard entry.outcomeEnum == .added else { return nil }

        // #177: an ingest can add itinerary items AND/OR log expenses. Undo
        // deletes both. There must be at least one of either to undo.
        let itemUUIDs = entry.addedItemUUIDList
        let expenseUUIDs = entry.addedExpenseUUIDList
        guard !itemUUIDs.isEmpty || !expenseUUIDs.isEmpty else { return nil }

        // Delete the exact itinerary items recorded on the log entry.
        for itemUUID in itemUUIDs {
            let fk = itemUUID
            if let row = try? store.context.fetch(
                FetchDescriptor<LocalItineraryItem>(predicate: #Predicate { $0.clientUUID == fk })
            ).first {
                store.context.delete(row)
            }
        }

        // Delete the exact expenses recorded on the log entry. `clientUUID` on
        // LocalExpense is a String, so match on the lowercased UUID string.
        for expenseUUID in expenseUUIDs {
            let key = expenseUUID.uuidString.lowercased()
            if let row = try? store.context.fetch(
                FetchDescriptor<LocalExpense>(predicate: #Predicate { $0.clientUUID == key })
            ).first {
                store.context.delete(row)
            }
        }

        // Bump the parent trip's updatedAt and grab its name for the message.
        // Optional: an expense-only ingest has no trip.
        var tripName: String? = nil
        if let tripUUID = entry.tripUUID {
            let tfk = tripUUID
            if let trip = try? store.context.fetch(
                FetchDescriptor<LocalTrip>(predicate: #Predicate { $0.clientUUID == tfk })
            ).first {
                trip.updatedAt = Date()
                tripName = trip.name
            }
        }

        // Rewrite the log entry to reflect the undo.
        entry.outcome = EmailIngestOutcome.skipped.rawValue
        entry.summary = Self.undoSummary(items: itemUUIDs.count, expenses: expenseUUIDs.count)
        entry.addedItemUUIDs = ""
        entry.addedExpenseUUIDs = ""

        try? store.context.save()
        // Fall back to a generic label when there's no trip (expense-only undo)
        // so the confirmation notification still reads sensibly.
        return tripName ?? "your finances"
    }

    /// Build the log summary shown after an undo, mentioning only non-zero
    /// counts.
    private static func undoSummary(items: Int, expenses: Int) -> String {
        var parts: [String] = []
        if items > 0 {
            parts.append(items == 1 ? "1 item" : "\(items) items")
        }
        if expenses > 0 {
            parts.append(expenses == 1 ? "1 expense" : "\(expenses) expenses")
        }
        let what = parts.isEmpty ? "nothing" : parts.joined(separator: " and ")
        return "Undone: removed \(what)."
    }

    // MARK: - Ledger

    private func isProcessed(key: String) -> Bool {
        let k = key
        let count = (try? store.context.fetchCount(
            FetchDescriptor<LocalProcessedEmail>(predicate: #Predicate { $0.messageKey == k })
        )) ?? 0
        return count > 0
    }

    private func recordProcessed(key: String, uid: Int, uidValidity: Int) {
        // Guard against a unique-constraint crash if it slipped in between.
        guard !isProcessed(key: key) else { return }
        let row = LocalProcessedEmail(messageKey: key, uid: uid, uidValidity: uidValidity)
        store.context.insert(row)
        try? store.context.save()
    }

    /// Remove any ledger rows for a key (used by the re-scan path).
    private func clearProcessed(key: String) {
        let k = key
        let rows = (try? store.context.fetch(
            FetchDescriptor<LocalProcessedEmail>(predicate: #Predicate { $0.messageKey == k })
        )) ?? []
        for row in rows { store.context.delete(row) }
        if !rows.isEmpty { try? store.context.save() }
    }

    // MARK: - Ingest log

    private func writeLog(message: EmailMessage, result: EmailIngestResult) {
        let entry = LocalEmailIngestLog(
            subject: message.subject,
            sender: message.from,
            outcome: result.outcome,
            summary: result.summary,
            tripUUID: result.tripUUID,
            addedItemUUIDs: result.addedItemUUIDs,
            addedExpenseUUIDs: result.addedExpenseUUIDs,
            debugBody: result.debugBody,
            debugTripContext: result.debugTripContext
        )
        store.context.insert(entry)
        try? store.context.save()

        // Fire the notification after the log row exists so undo has a target.
        let logUUID = entry.clientUUID
        switch result.outcome {
        case .added:
            // tripName is nil for an expense-only add (a receipt with no
            // matched trip). Pass it through so the notification body can adapt
            // (#177).
            let count = result.addedItemUUIDs.count
            let updated = result.updatedItemUUIDs.count
            let expenses = result.addedExpenseUUIDs.count
            Task {
                await EmailIngestNotifications.postAdded(
                    tripName: result.tripName,
                    itemCount: count,
                    updatedCount: updated,
                    expenseCount: expenses,
                    logUUID: logUUID
                )
            }
        case .skipped:
            Task { await EmailIngestNotifications.postSkipped(subject: message.subject) }
        case .failed:
            break
        }
    }

    /// Record a fetch/parse/transport exception as a visible log row so the
    /// failure isn't invisible (#143). We don't have a parsed message here, so
    /// the row carries the UID and the error text.
    private func writeFailureLog(uid: Int, error: Error) {
        let entry = LocalEmailIngestLog(
            subject: "(email uid \(uid))",
            sender: "",
            outcome: .failed,
            summary: "Couldn't process this email: \(error.localizedDescription)",
            debugBody: "",
            debugTripContext: ""
        )
        store.context.insert(entry)
        try? store.context.save()
    }

    /// Keep the ingest log to the most recent 100 entries.
    private func trimLog() {
        var descriptor = FetchDescriptor<LocalEmailIngestLog>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1000
        guard let all = try? store.context.fetch(descriptor), all.count > 100 else { return }
        for stale in all[100...] {
            store.context.delete(stale)
        }
        try? store.context.save()
    }
}

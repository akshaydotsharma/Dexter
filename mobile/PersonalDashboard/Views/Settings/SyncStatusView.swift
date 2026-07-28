import SwiftUI
import SwiftData

/// Detailed sync status (#348).
///
/// The detail level here is not indulgence. Two things depend on it:
///
/// 1. A silently stale bookmark is a known failure mode of this transport. Sync
///    just stops, with nothing thrown and nothing logged. Health has to be
///    legible or the failure is invisible.
/// 2. Phase 1 is a dry run, and the dry run IS the test harness for local change
///    capture. "14 ops pending, 12 of them tasks" can be checked against what you
///    actually did on the other device. "Healthy" cannot be checked against
///    anything. Without the numbers there is no way to know whether the change
///    detector is complete before phase 2 starts trusting it.
struct SyncStatusView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var coordinator = SyncCoordinator.shared
    @AppStorage(SyncSettings.Key.enabled) private var enabled = false
    @AppStorage(SyncSettings.Key.applyEnabled) private var applyEnabled = false

    @State private var showReplayConfirm = false
    @State private var isReplaying = false
    @State private var replayMessage: String?

    private var snapshot: SyncStatusSnapshot { coordinator.snapshot }

    /// The rows, shared by both platforms. Only the container around them differs.
    @ViewBuilder
    private var sections: some View {
        dryRunBanner
        folderSection
        thisDeviceSection
        pendingSection
        peersSection
        lastPassSection
        actionsSection
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    // MARK: - iOS

    #if !os(macOS)
    private var iosBody: some View {
        NavigationStack {
            List {
                sections
            }
            .navigationTitle("Sync")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                        .disabled(coordinator.isSyncing)
                }
            }
        }
        .onAppear { coordinator.refreshStatus() }
    }
    #endif

    // MARK: - macOS

    // Presented as a POPOVER by `SettingsView`, not a sheet, and built on `Form`
    // rather than `List`. Both halves matter, and #351 was caused by getting both
    // wrong by reusing the iOS shape unchanged:
    //
    // - `presentationDetents` do nothing on macOS, so a `.sheet` becomes a small
    //   centred window that clips its own content. #341 hit this with the Finance
    //   filter sheets and settled on an anchored popover; this follows that.
    // - A `List` inside a macOS sheet or popover with no explicit frame collapses
    //   to zero height, which is why #351 showed a title and a Done button and
    //   nothing else. `Form` with `.grouped` sizes correctly and keeps the
    //   grouped-row look the same rows have on iOS.
    //
    // The explicit frame is required: a popover has no intrinsic size to inherit.
    // No Done button, because a popover dismisses by clicking away.
    #if os(macOS)
    static let popoverSize = CGSize(width: 460, height: 620)

    private var macBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sync")
                    .font(.edHeading)
                    .foregroundStyle(Tokens.ink)
                Spacer()
                if coordinator.isSyncing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)

            Rectangle().fill(Tokens.divider).frame(height: 0.5)

            Form {
                sections
            }
            .formStyle(.grouped)
        }
        .frame(width: Self.popoverSize.width, height: Self.popoverSize.height)
        .onAppear { coordinator.refreshStatus() }
    }
    #endif

    // MARK: - Banner

    private var dryRunBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(applyEnabled ? "Applying changes" : "Dry run",
                      systemImage: applyEnabled ? "arrow.triangle.2.circlepath" : "eye")
                    .font(.headline)
                    .foregroundStyle(applyEnabled ? Color.orange : Color.primary)
                Text(applyEnabled
                     ? "Sync is applying the other device's changes to this device. When the same record is edited in both places, the most recent edit wins and the other is discarded."
                     : "Sync is recording your changes and reading the other device's changes, but it is not applying anything yet. Nothing on this device can be modified or deleted by sync.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Folder

    private var folderSection: some View {
        Section("Shared folder") {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Image(systemName: healthIcon)
                        .foregroundStyle(healthColor)
                    Text(snapshot.health.label)
                        .multilineTextAlignment(.trailing)
                }
            }
            if case .notConfigured = snapshot.health {
                Text("Pick a backup folder in Backup settings first. Sync shares it unless you choose a separate folder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Toggle("Sync automatically", isOn: $enabled)
                .disabled(!snapshot.health.isUsable)
            // Separate from the toggle above, on purpose. Publishing your own log
            // cannot damage anything; accepting a peer's changes can. Turning this
            // on should be a deliberate act, not a consequence.
            Toggle("Apply changes from other devices", isOn: $applyEnabled)
                .disabled(!snapshot.health.isUsable)
            if applyEnabled {
                Text("A backup is written before the first apply, and sync refuses to apply anything if that backup fails. Receipt images do not travel between devices yet, so a synced expense may show a missing receipt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if snapshot.hasLegacyFolder {
                Text("An old \"DexterSync\" folder is still in there from before the layout changed. Sync no longer uses it and you can delete it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var healthIcon: String {
        switch snapshot.health {
        case .valid:          return "checkmark.circle.fill"
        case .notConfigured:  return "circle.dashed"
        case .stale, .accessDenied: return "exclamationmark.triangle.fill"
        case .failed:         return "xmark.octagon.fill"
        }
    }

    private var healthColor: Color {
        switch snapshot.health {
        case .valid:          return .green
        case .notConfigured:  return .secondary
        case .stale, .accessDenied: return .orange
        case .failed:         return .red
        }
    }

    // MARK: - This device

    private var thisDeviceSection: some View {
        Section("This device") {
            LabeledContent("Name", value: snapshot.deviceName.isEmpty ? "Not registered" : snapshot.deviceName)
            LabeledContent("Device ID", value: shortID(snapshot.deviceUUID))
            // The Lamport clock is surfaced because it is the only way to tell
            // "the peer has not written anything" from "we never read the peer".
            LabeledContent("Clock", value: "\(snapshot.lamport)")
            LabeledContent("Next segment", value: "#\(snapshot.nextSegmentSequence)")
            LabeledContent("Ops emitted", value: "\(snapshot.opsEmitted)")
            LabeledContent("Last emit", value: relative(snapshot.lastEmitAt))
            LabeledContent("Tracked records", value: "\(snapshot.shadowCount)")
            LabeledContent("Tombstones", value: "\(snapshot.tombstoneCount)")
        }
    }

    // MARK: - Pending

    // Split into small explicitly-typed pieces rather than one long Section
    // body. SwiftUI's result-builder type inference gives up on chains of
    // `LabeledContent` mixed with conditionals and a ForEach, and reports it as
    // "unable to type-check in reasonable time" rather than as a real error.
    private var pendingSection: some View {
        Section {
            pendingTotals
            ForEach(sortedPending, id: \.entity) { entry in
                PendingEntityRow(label: friendlyEntity(entry.entity), count: entry.count)
            }
        } header: {
            Text("Pending locally")
        } footer: {
            Text("Recomputed each time this screen opens by comparing every record against what was last sent. The first run counts everything, because nothing has been sent yet.")
        }
    }

    @ViewBuilder
    private var pendingTotals: some View {
        LabeledContent("Changes to send", value: String(snapshot.pendingTotal))
        if snapshot.pendingUpserts > 0 {
            LabeledContent("Creates and edits", value: String(snapshot.pendingUpserts))
        }
        if snapshot.pendingDeletes > 0 {
            LabeledContent("Deletes", value: String(snapshot.pendingDeletes))
        }
    }

    private struct PendingEntry: Identifiable {
        let entity: String
        let count: Int
        var id: String { entity }
    }

    private struct PendingEntityRow: View {
        let label: String
        let count: Int

        var body: some View {
            LabeledContent(label, value: String(count))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Biggest contributors first, so the row that explains an unexpected count
    /// is at the top instead of buried alphabetically.
    private var sortedPending: [PendingEntry] {
        let entries: [PendingEntry] = snapshot.pendingByEntity.map { pair in
            PendingEntry(entity: pair.key, count: pair.value)
        }
        return entries.sorted { (lhs: PendingEntry, rhs: PendingEntry) -> Bool in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.entity < rhs.entity
        }
    }

    // MARK: - Peers

    private var peersSection: some View {
        Section {
            if snapshot.peers.isEmpty {
                Text("No other device has registered in this folder yet. Open Dexter on your other device with sync pointed at the same folder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.peers) { peer in
                    PeerRow(peer: peer, shortID: shortID(peer.id), lastSeen: relative(peer.lastSeenAt))
                }
            }
        } header: {
            Text("Other devices")
        } footer: {
            Text("\"Segments applied\" counts only what has been through the applier. Segments read while applying was switched off are counted separately and called out, because they are not picked up on their own.")
        }
    }

    /// Extracted into its own `View` rather than inlined in the `ForEach`. Same
    /// reason as `pendingSection`: nested stacks of `Text` with interpolation
    /// inside a `Section` inside a `ForEach` push SwiftUI's type inference past
    /// its budget, and it surfaces as a spurious "unable to type-check" error.
    private struct PeerRow: View {
        let peer: SyncStatusSnapshot.Peer
        let shortID: String
        let lastSeen: String

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(peer.name).font(.subheadline.weight(.medium))
                    Spacer()
                    if peer.isBehind {
                        Text("behind")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                    }
                }
                Text(shortID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(progressLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                unappliedLine
                Text("Last seen \(lastSeen)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = peer.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 2)
        }

        private var progressLine: String {
            "Segments applied \(peer.highestSegmentRead) of \(peer.highestSegmentAvailable) · \(peer.opsDecoded) ops decoded · \(peer.opsWouldApply) would apply"
        }

        /// The #380 diagnostic. Segments read while applying was off used to look
        /// exactly like segments that had been applied, so a device could sit on a
        /// permanently skipped baseline while this row said it was caught up.
        @ViewBuilder
        private var unappliedLine: some View {
            if peer.unappliedSegmentCount > 0 {
                Text("\(peer.unappliedSegmentCount) segment\(peer.unappliedSegmentCount == 1 ? "" : "s") read before applying was on, never applied. Use \"Re-apply everything\" below to pick them up.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Last pass

    private var lastPassSection: some View {
        Section("Last sync pass") {
            LabeledContent("Started", value: relative(snapshot.lastPassStartedAt))
            LabeledContent("Duration", value: snapshot.lastPassStartedAt == nil ? "—" : "\(snapshot.lastPassDurationMS) ms")
            LabeledContent("Sent", value: "\(snapshot.lastPassOpsOut)")
            LabeledContent("Read", value: "\(snapshot.lastPassOpsIn)")
            LabeledContent("Outcome") {
                Text(snapshot.lastPassOutcome.isEmpty ? "Never run" : snapshot.lastPassOutcome)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(outcomeIsError ? .orange : .secondary)
            }
        }
    }

    private var outcomeIsError: Bool {
        let outcome = snapshot.lastPassOutcome
        return !outcome.isEmpty && !outcome.hasPrefix("OK")
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            Button {
                Task {
                    await coordinator.syncNow()
                }
            } label: {
                HStack {
                    Text("Sync now")
                    if coordinator.isSyncing {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(coordinator.isSyncing || !snapshot.health.isUsable)

            replayButton
            if let replayMessage {
                Text(replayMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Re-apply reads every segment the other device has ever written, from the first one, instead of only new ones. It is the way to recover changes that were read while applying was switched off. A backup is written first, and anything newer on this device still wins.")
        }
    }

    /// The #380 repair. Deliberately a separate, confirmed action rather than
    /// something a pass does on its own: replaying a whole log is the largest write
    /// sync can make, and the one case it gets wrong (recreating a record deleted
    /// here before sync ever ran) is worth a sentence of warning first.
    private var replayButton: some View {
        Button(role: .destructive) {
            showReplayConfirm = true
        } label: {
            HStack {
                Text("Re-apply everything")
                if isReplaying {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(coordinator.isSyncing || isReplaying || !snapshot.health.isUsable || !applyEnabled)
        .confirmationDialog(
            "Re-apply everything from other devices?",
            isPresented: $showReplayConfirm,
            titleVisibility: .visible
        ) {
            Button("Re-apply everything", role: .destructive) {
                Task { await runReplay() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every change the other device has ever published gets read again. Newer edits on this device are kept, and deletions made here since sync started stay deleted. Something you deleted here before sync was set up can come back if the other device still has it. A backup is written before anything is applied.")
        }
    }

    private func runReplay() async {
        isReplaying = true
        let outcome = await coordinator.replayPeerLogs()
        isReplaying = false
        switch outcome {
        case .done(let peersRewound, let applied):
            replayMessage = peersRewound == 0
                ? "Nothing to re-read: no other device has been read yet."
                : "Re-read \(peersRewound) device\(peersRewound == 1 ? "" : "s") and applied \(applied) record\(applied == 1 ? "" : "s")."
        case .blockedApplyOff:
            replayMessage = "Turn on \"Apply changes from other devices\" first, or this would read the log again and change nothing."
        case .blockedNoBackup:
            replayMessage = "Pick a backup folder first. Re-applying is only allowed with a backup behind it."
        case .failed(let message):
            replayMessage = "Could not re-apply: \(message)"
        }
    }

    // MARK: - Formatting

    /// First 8 characters. Enough to tell two devices apart at a glance without
    /// making the row unreadable, and enough to match against a folder name in
    /// Finder when debugging.
    private func shortID(_ uuid: UUID?) -> String {
        guard let uuid else { return "—" }
        return String(uuid.uuidString.prefix(8))
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Map the Swift model name onto the label the user sees elsewhere in the app.
    private func friendlyEntity(_ entity: String) -> String {
        switch entity {
        case "LocalTodo":            return "Tasks"
        case "LocalNote":            return "Notes"
        case "LocalNoteFolder":      return "Note folders"
        case "LocalList":            return "Lists"
        case "LocalTrip":            return "Trips"
        case "LocalItineraryItem":   return "Itinerary items"
        case "LocalExpense":         return "Expenses"
        case "LocalKeyword":         return "Vocabulary"
        case "RecurringExpense":     return "Recurring expenses"
        case "LocalPerson":          return "People"
        case "LocalEvent":           return "Events"
        case "LocalStatementImport": return "Statement imports"
        case "LocalProcessedEmail":  return "Processed emails"
        default:                     return entity
        }
    }
}

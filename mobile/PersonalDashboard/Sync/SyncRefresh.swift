import SwiftUI

// Manual refresh affordance for synced surfaces (#363).
//
// ## Why this exists at all, given the notification already works
//
// `localStoreDidChange` makes a peer's change appear without the user doing
// anything, so the reported symptom is already gone. This is the other half:
// a way to ASK. When an expected change has not turned up, the honest question
// is "has it reached the shared folder yet", not "has this view re-read" — so a
// manual refresh has to run a real sync pass, not just reload from the local
// store. A button that only re-reads what is already on disk would answer a
// question nobody asked and, worse, would look like it had checked.
//
// ## Why the two platforms get different affordances
//
// `.refreshable` is the whole story on iOS: it installs the standard
// pull-to-refresh gesture and its spinner runs for exactly as long as the
// closure. On macOS the same modifier compiles, is accepted, and renders NO
// affordance in a `List` — there is no pull gesture on a trackpad-scrolled
// window. So the Mac gets a toolbar button and ⌘R instead, which is what
// Mail's "Get Mail" does and what a Mac user will actually reach for.
//
// ## Why macOS needs no per-view wiring
//
// Sync is process-global, and the four cached surfaces (Tasks, Notes, Lists,
// Today) already observe `localStoreDidChange`. So one global command can drive
// every section, and `refreshNow` posts that notification unconditionally —
// including when the pass brought nothing back — so "refresh" always means a
// re-read actually happened. That is why there is no `refreshAction` focused
// scene value here paralleling `newItemAction`: ⌘N has to reach one specific
// section's create action, but refresh has nothing per-section to reach.

extension View {

    /// Pull-to-refresh that runs a real sync pass before reloading.
    ///
    /// `reload` re-reads the surface's own view model. It is still awaited even
    /// though the pass posts `localStoreDidChange`, for two reasons: the
    /// notification path hops through `Task { load() }`, so the spinner would
    /// stop before the rows changed, and awaiting the reload directly is what
    /// makes the spinner's duration honest.
    ///
    /// No-op on macOS, deliberately — see the file comment. The Mac affordance
    /// is `MacSyncRefreshButton` in the window toolbar plus ⌘R.
    @ViewBuilder
    func syncRefreshable(_ reload: @escaping @Sendable () async -> Void) -> some View {
        #if os(iOS)
        self.refreshable {
            await SyncCoordinator.shared.refreshNow(reason: "pull-to-refresh")
            await reload()
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
/// The window-toolbar refresh control (#363).
///
/// Shows a spinner while a pass is in flight rather than a static glyph. Without
/// it, a pass that takes a second or two over iCloud is indistinguishable from a
/// button that did nothing, which is the exact confusion this affordance exists
/// to remove.
struct MacSyncRefreshButton: View {

    /// Read (not `@State`) on purpose: the coordinator is an `@Observable`
    /// singleton, and reading `isSyncing` inside `body` is all the Observation
    /// framework needs to re-render this view when it flips.
    private let coordinator = SyncCoordinator.shared

    var body: some View {
        Button {
            Task { await coordinator.refreshNow(reason: "toolbar") }
        } label: {
            if coordinator.isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .help("Check the sync folder for changes (⌘R)")
        .disabled(coordinator.isSyncing)
        .accessibilityLabel("Refresh")
    }
}
#endif

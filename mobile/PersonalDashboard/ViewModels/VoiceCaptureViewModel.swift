import Foundation
import Observation
import os
import Speech
import AVFoundation
import UIKit

/// Drives the global full-screen voice-capture overlay (issue #150 → #156,
/// one-shot capture per open).
///
/// Owns the SINGLE `SpeechTranscriber` instance for the whole app and the AI
/// execute path. Injected into the SwiftUI environment from `ContentView` so
/// the overlay (attached once at the root via `.fullScreenCover`) and
/// `ChatView`'s inline mic button both drive the same transcriber — there is
/// never a second instance that could install a duplicate audio tap and crash
/// the engine (the re-entry guard in `SpeechTranscriber` backs this up).
///
/// ### One-shot capture (issue #156)
///
/// Each long-press opens the overlay for EXACTLY ONE action, then closes itself.
/// The transcriber (OpenAI server_vad OR on-device synthesized VAD) hands us the
/// FIRST finalized utterance via `SpeechTranscriber.onUtteranceFinalized`. The
/// instant that first utterance lands we `transcriber.stop()` so no second
/// utterance can be captured, and a `hasConsumedUtterance` latch drops anything
/// that slipped into the queue before the stop took effect. That one utterance
/// executes standalone (`chat.reset()` then `chat.send()`), its result rows flash
/// for ~1.2s, and then the overlay AUTO-DISMISSES (`shouldDismiss` flips true,
/// the view sets `isPresented = false`). To do another action the user
/// long-presses again.
///
/// Empty (silence) and error do NOT auto-dismiss: the user retries via Try Again
/// or bails via Done / Cancel. Every close path — auto-dismiss OR manual — funnels
/// through the cover's `onDismiss` → `teardown()`, which is idempotent.
///
/// The state machine is the source of truth for the overlay UI:
///   listening → executing → flashSuccess → (auto-dismiss)   (the happy path)
///   listening → empty / error / permissionDenied            (recoverable via resume)
@Observable
@MainActor
final class VoiceCaptureViewModel {

    /// The one-shot state machine (issue #156). `.flashSuccess` is terminal for
    /// the session: it does NOT return to `.listening`; instead the overlay
    /// auto-dismisses after the flash. `.empty` / `.error` stay open for retry.
    enum State: Equatable {
        case listening          // recording, InkOrb reactive, socket alive
        case executing          // the one utterance's AI call is in flight
        case flashSuccess       // its result rows, ~1.2s, then auto-dismiss
        case empty              // silence / nothing captured yet (informational)
        case permissionDenied   // mic / speech permission denied
        case error(String)      // transcription or AI failure (message)
    }

    /// Voice-pipeline diagnostics (issue #151). Same subsystem as the
    /// transcriber + socket client so one Console.app filter shows the whole
    /// overlay flow: state transitions, silence-timer fire, finalize snapshot.
    private static let log = Logger(
        subsystem: "com.akshaysharma.personaldashboard.voice",
        category: "VoiceCaptureViewModel"
    )

    /// The single shared transcriber. Exposed so `ChatView`'s inline mic and
    /// the overlay both read the same instance (audioLevel, transcript, etc.).
    let transcriber = SpeechTranscriber()

    private(set) var state: State = .listening {
        didSet {
            guard state != oldValue else { return }
            Self.log.info("state: \(String(describing: oldValue), privacy: .public) → \(String(describing: self.state), privacy: .public)")
        }
    }

    /// Success rows for the current flash — one per applied action of the
    /// utterance that just executed. Cleared when the flash ends.
    private(set) var successLabels: [String] = []

    /// Error/AI message surfaced in the error state.
    private(set) var errorMessageText: String?

    /// One-shot auto-dismiss signal (issue #156). Flipped true after the success
    /// flash elapses; the overlay observes it via `.onChange` and sets
    /// `isPresented = false`, which closes the cover and funnels through
    /// `teardown()`. The VM never touches the router/binding directly — it only
    /// publishes intent, the view owns the presentation binding. Empty / error
    /// states never set this, so they stay open for retry.
    private(set) var shouldDismiss: Bool = false

    /// Live transcript convenience (reads through to the transcriber). The
    /// overlay binds to this while listening to show the running text.
    var transcript: String { transcriber.transcript }

    /// Normalized mic amplitude (0–1) for the InkOrb.
    var audioLevel: Float { transcriber.audioLevel }

    /// The text of the utterance currently executing / just flashed. Shown muted
    /// under the working / success rows so the user sees which command it maps to.
    private(set) var currentUtterance: String = ""

    /// Swipe-to-dismiss is disabled while capturing / executing / flashing so a
    /// stray swipe never drops the mic mid-command (the overlay auto-dismisses on
    /// success anyway). Permission / hard-error states allow it as an escape hatch.
    var allowsInteractiveDismiss: Bool {
        switch state {
        case .listening, .executing, .flashSuccess, .empty: return false
        case .permissionDenied, .error: return true
        }
    }

    // MARK: Private

    /// The overlay runs its own `ChatViewModel` so the AI execute path is
    /// identical to the chat surface (same streaming service + executor),
    /// without coupling to `ChatView`'s on-screen conversation.
    private let chat = ChatViewModel()

    /// How long the one utterance's result rows stay on screen before the
    /// overlay auto-dismisses (issue #156). Kept brief so the green-check
    /// confirmation registers without making the user wait to do the next thing.
    private let successFlashDelay: TimeInterval = 1.2

    /// One-shot latch (issue #156). Set true the instant the FIRST finalized
    /// utterance is accepted. Guards the enqueue hook AND the drain loop so a
    /// second utterance that slipped into the queue before `transcriber.stop()`
    /// took effect is dropped rather than executed. Reset by `begin()`.
    private var hasConsumedUtterance = false

    /// Unbounded queue of finalized-and-normalized utterances (issue #156).
    /// `SpeechTranscriber.onUtteranceFinalized` yields into this the instant a
    /// server_vad segment finalizes; `processingLoop` drains it serially. The
    /// stream buffers utterances spoken while an execution is in flight, so none
    /// is ever dropped and two never overlap.
    private var utteranceContinuation: AsyncStream<String>.Continuation?

    /// The single serial task that pulls utterances off the queue and executes
    /// them one at a time. Runs for the life of the session; cancelled by
    /// `teardown()`. Awaiting each `runUtterance` before the next `for await`
    /// iteration is what serializes execution.
    private var processingLoop: Task<Void, Never>?

    // MARK: Lifecycle

    /// Called when the overlay appears. Starts a fresh continuous session:
    /// wires the per-utterance queue, kicks off the serial processing loop, and
    /// starts listening.
    func begin() {
        successLabels = []
        errorMessageText = nil
        currentUtterance = ""
        // Fresh one-shot session: clear the consumed latch and the auto-dismiss
        // signal so the previous open's flags never leak into this one (issue #156).
        hasConsumedUtterance = false
        shouldDismiss = false
        // Reset to .listening SYNCHRONOUSLY so the first render on (re)open never
        // shows a stale terminal state from a prior session (issue #151).
        state = .listening
        startProcessingLoop()
        Task { await startListening() }
    }

    /// Wire the utterance queue + serial drain loop (issue #156, one-shot).
    /// Only the FIRST finalized utterance is accepted: the enqueue hook latches
    /// `hasConsumedUtterance` and stops the transcriber the instant it lands, and
    /// the drain loop consumes exactly one utterance then returns. A second
    /// utterance that raced past the stop is dropped by BOTH the hook guard and
    /// the loop's post-drain break, so it can never execute.
    private func startProcessingLoop() {
        processingLoop?.cancel()
        // Build the stream + continuation. Unbounded buffering is harmless here —
        // the latch drops everything after the first, so at most one is consumed.
        let (stream, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .unbounded
        )
        utteranceContinuation = continuation

        // The transcriber fires this on the main actor for every finalized,
        // Devanagari-normalized utterance. Accept the FIRST non-empty one only:
        // latch immediately and STOP the transcriber so no further audio is
        // captured or segmented. Empties (silence) don't latch — the user may
        // still speak. Anything after the latch is ignored here.
        transcriber.onUtteranceFinalized = { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard !self.hasConsumedUtterance else {
                Self.log.info("utterance ignored — already consumed one this session")
                return
            }
            self.hasConsumedUtterance = true
            // Stop capture on the FIRST finalize so the recognizer can't produce
            // (or enqueue) a second utterance. `stop()` is idempotent and safe to
            // call while an execute is about to run.
            self.transcriber.stop()
            Self.log.info("first utterance accepted (len=\(trimmed.count, privacy: .public)); transcriber stopped")
            self.utteranceContinuation?.yield(trimmed)
        }

        processingLoop = Task { [weak self] in
            for await utterance in stream {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.runUtterance(utterance)
                // One-shot: after the single utterance executes and flashes we're
                // done consuming — break so any buffered straggler never runs.
                // `runUtterance` triggers the auto-dismiss on success.
                return
            }
        }
    }

    /// Start (or resume) recording. Used by `begin()` and by Try Again after an
    /// empty / error state. The transcriber's own re-entry guard makes a
    /// redundant start a no-op, and the socket stays alive across utterances so
    /// this is only a real start at session open (or after a hard failure).
    func startListening() async {
        successLabels = []
        errorMessageText = nil
        currentUtterance = ""
        state = .listening

        // Permission gate up front so denial routes to the permission state.
        if Self.permissionDenied {
            state = .permissionDenied
            return
        }
        if !transcriber.isRecording {
            await transcriber.toggle()
            if !transcriber.isRecording {
                routeStartFailure()
            }
        }
    }

    /// A transcriber error surfaced asynchronously (most commonly a connection
    /// failure: the WebSocket never came up on a weak link, issue #151). The
    /// transcriber has already torn its socket down and flipped `isRecording`
    /// false, so listening can't continue. Route the overlay to its error state
    /// with the friendly message rather than hanging. Doesn't override an
    /// in-flight execute / flash (that cycle owns the UI and will return to
    /// listening on its own — but with the socket dead there'll be no further
    /// utterances, which is an acceptable degrade; the user can Try Again).
    func handleTranscriberError(_ message: String) {
        switch state {
        case .listening, .empty:
            Self.log.info("transcriber error while idle-listening → error state")
            errorMessageText = Self.stripTechnicalPrefix(message)
            state = .error(errorMessageText ?? "Something went wrong.")
        case .executing, .flashSuccess, .permissionDenied, .error:
            // A live execute/flash owns the UI; a terminal state already shows a
            // message. Don't stomp either.
            break
        }
    }

    /// Execute the one accepted utterance end-to-end, flash its result, then
    /// auto-dismiss the overlay (issue #156, one-shot). Called exactly once per
    /// session by `processingLoop`. The transcriber was already stopped by the
    /// enqueue hook when this utterance was accepted, so no more audio flows.
    private func runUtterance(_ utterance: String) async {
        let input = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        currentUtterance = input
        successLabels = []
        errorMessageText = nil
        state = .executing
        Self.log.info("executing utterance (len=\(input.count, privacy: .public))")

        // Each utterance is a standalone, stateless capture (issue #156):
        // `reset()` clears the overlay's own conversation so `send()` replays NO
        // prior history. Otherwise earlier utterances re-issue their tool calls
        // and duplicate items. The queue serializes calls, so this reset can
        // never race a concurrent send.
        chat.reset()
        chat.draftInput = input
        await chat.send()

        if Task.isCancelled { return }

        if let err = chat.errorMessage {
            errorMessageText = Self.stripTechnicalPrefix(err)
            state = .error(errorMessageText ?? "Something went wrong.")
            return
        }

        let results = chat.turns.last(where: { $0.role == .assistant })?.results ?? []
        let applied = results.filter { !$0.isFailure }
        successLabels = applied.isEmpty ? ["Message sent"] : applied.map(Self.successLabel(for:))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        state = .flashSuccess

        // Hold the result rows briefly so the user sees the green-check
        // confirmation, then AUTO-DISMISS (issue #156, one-shot). Cancellation
        // (teardown — e.g. the user tapped Done during the flash) short-circuits
        // the wait; we then skip the dismiss signal since the cover is already
        // closing.
        try? await Task.sleep(nanoseconds: UInt64(successFlashDelay * 1_000_000_000))
        if Task.isCancelled { return }

        // Signal the overlay to close itself. Only if we're still on the success
        // flash (a transcriber error arriving during the flash would have flipped
        // us to .error, which stays open for retry). The view observes
        // `shouldDismiss` and sets `isPresented = false`, funnelling through the
        // single `teardown()` path.
        if case .flashSuccess = state {
            shouldDismiss = true
        }
    }

    /// Manual "Stop Recording" (issue #156). Ends capture immediately and runs
    /// whatever the user has said SO FAR, rather than waiting for the automatic
    /// server_vad / silence-timer finalize. Only meaningful while `.listening`.
    ///
    /// Race guard: the automatic finalize (`onUtteranceFinalized`) may fire at
    /// nearly the same instant. Both paths funnel through the SAME
    /// `hasConsumedUtterance` latch, checked-and-set on the @MainActor here with
    /// no `await` in between, so exactly one wins. Whichever set the latch first
    /// executes its utterance; the loser bails. This method takes a synchronous
    /// snapshot of the live `transcript` BEFORE latching so the spoken text can't
    /// be lost to a concurrent reset.
    ///
    /// - Non-empty snapshot → latch, stop the transcriber, and yield the snapshot
    ///   to the same queue the auto-path uses (`processingLoop` runs it: executing
    ///   → flash → auto-dismiss).
    /// - Empty snapshot (stopped before speaking) → do NOT latch (the user may
    ///   still be about to speak on a retry); stop the transcriber and route to
    ///   `.empty` so they get Try Again / Done rather than a silent close.
    func stopRecordingAndExecute() {
        // Only act while listening — in executing / flashSuccess the capture is
        // already done and the button isn't shown; guard defensively anyway.
        guard case .listening = state else { return }

        // Snapshot the live partial transcript BEFORE any latch/stop so a
        // near-simultaneous auto-finalize (which clears/rotates transcript) can't
        // race the text out from under us.
        let snapshot = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        // If the auto-path already consumed an utterance this session, it owns the
        // execution — do nothing (no double-run, no double-dismiss). This is the
        // same latch the enqueue hook checks; both run on the @MainActor so the
        // check-and-set below is atomic w.r.t. the auto-path.
        guard !hasConsumedUtterance else {
            Self.log.info("manual stop ignored — auto-finalize already consumed the utterance")
            return
        }

        if snapshot.isEmpty {
            // Nothing said yet. Stop capture and surface the informational empty
            // state (Try Again / Done) — never latch, never silently close.
            Self.log.info("manual stop with empty transcript → empty state")
            transcriber.stop()
            successLabels = []
            errorMessageText = nil
            state = .empty
            return
        }

        // Win the race: latch first so the auto-path's enqueue hook drops any
        // finalize that lands after this point, then stop the transcriber and hand
        // the snapshot to the shared queue. Same downstream path as the automatic
        // finalize — the processing loop executes it exactly once.
        hasConsumedUtterance = true
        transcriber.stop()
        Self.log.info("manual stop accepted (len=\(snapshot.count, privacy: .public)); transcriber stopped, yielding to queue")
        utteranceContinuation?.yield(snapshot)
    }

    /// Try Again after an empty / error state — re-arm a fresh one-shot capture
    /// (issue #156). The socket may be dead (a connection failure tore it down)
    /// and, if we'd already accepted an utterance, the processing loop has
    /// returned and the transcriber is stopped. So fully re-arm: clear the
    /// consumed latch, rebuild the processing loop + enqueue hook, and start
    /// listening (which reopens the socket). This mirrors `begin()` minus the
    /// synchronous state reset, which `startListening()` handles.
    func retryExecute() {
        hasConsumedUtterance = false
        shouldDismiss = false
        startProcessingLoop()
        Task { await startListening() }
    }

    /// End the session. The single teardown path, called from the
    /// `.fullScreenCover` `onDismiss` regardless of how it closed: the one-shot
    /// auto-dismiss (success), Done / Cancel, or a permission/error escape.
    /// Idempotent — detaches the transcriber hook, finishes the utterance stream
    /// (so the loop's `for await` completes), cancels the loop (which also cancels
    /// any in-flight execute/flash `await`), and stops the mic + socket (a no-op
    /// if the one-shot already stopped it on first finalize).
    func teardown() {
        Self.log.info("teardown: ending session")
        // Detach first so no late `…completed` enqueues after we finish.
        transcriber.onUtteranceFinalized = nil
        // Finishing the stream lets the loop's `for await` exit cleanly; also
        // cancel it so a currently-executing `runUtterance` (mid chat.send() or
        // mid flash-sleep) stops promptly rather than draining the queue.
        utteranceContinuation?.finish()
        utteranceContinuation = nil
        processingLoop?.cancel()
        processingLoop = nil
        transcriber.stop()
    }

    /// Open the system Settings app (permission-denied state).
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: Helpers

    private func routeStartFailure() {
        if Self.permissionDenied {
            state = .permissionDenied
        } else if let msg = transcriber.errorMessage {
            errorMessageText = msg
            state = .error(msg)
        }
        // Otherwise stay in .listening; a later utterance / transcriber error
        // will drive the next transition.
    }

    /// True when speech recognition OR microphone access is denied/restricted.
    private static var permissionDenied: Bool {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let speechBad = (speech == .denied || speech == .restricted)
        let micBad: Bool
        if #available(iOS 17.0, *) {
            micBad = (AVAudioApplication.shared.recordPermission == .denied)
        } else {
            micBad = (AVAudioSession.sharedInstance().recordPermission == .denied)
        }
        return speechBad || micBad
    }

    /// "Task added: Call John" style label for a success row, mirroring the
    /// chat result-card vocabulary (entity word + verb + title).
    private static func successLabel(for result: ChatActionResult) -> String {
        let entity = entityWord(for: result.actionType).capitalized
        let verb: String
        switch result.state {
        case .created: verb = "added"
        case .deleted: verb = "removed"
        case .updated: verb = "updated"
        case .error:   verb = "failed"
        }
        if let title = result.title, !title.isEmpty {
            return "\(entity) \(verb): \(title)"
        }
        return "\(entity) \(verb)"
    }

    /// Mirrors `ChatResultCard.entityWord` so the overlay's rows read the same.
    private static func entityWord(for actionType: DraftActionType) -> String {
        switch actionType {
        case .createTodo, .updateTodo, .completeTodo, .deleteTodo: return "task"
        case .createNote, .updateNote, .appendToNote, .deleteNote: return "note"
        case .createList, .updateList, .deleteList, .addToList:    return "list"
        case .updateListItem, .removeListItem:                     return "item"
        case .updateFolder, .deleteFolder:                         return "folder"
        case .createTrip, .updateTrip, .deleteTrip, .addItineraryItems: return "trip"
        case .updateItineraryItem, .deleteItineraryItem:           return "item"
        case .addExpense:                                          return "expense"
        case .addRecurringExpense:                                 return "recurring expense"
        case .clearExpenses:                                       return "expenses"
        case .unknown:                                             return "action"
        }
    }

    /// Strip a leading technical prefix from an AI/transcriber error.
    private static func stripTechnicalPrefix(_ message: String) -> String {
        if let range = message.range(of: ": ", options: .backwards),
           message.distance(from: message.startIndex, to: range.lowerBound) < 40 {
            return String(message[range.upperBound...])
        }
        return message
    }
}

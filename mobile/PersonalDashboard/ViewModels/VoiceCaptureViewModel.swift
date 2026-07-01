import Foundation
import Observation
import os
import Speech
import AVFoundation
import UIKit

/// Drives the global full-screen voice-capture overlay (issue #150, revised
/// auto-execute concept).
///
/// Owns the SINGLE `SpeechTranscriber` instance for the whole app, the 1.5s
/// silence-finalize timer, the 1.5s safety-window timer, and the AI execute
/// path. Injected into the SwiftUI environment from `ContentView` so the
/// overlay (attached once at the root via `.fullScreenCover`) and `ChatView`'s
/// inline mic button both drive the same transcriber — there is never a second
/// instance that could install a duplicate audio tap and crash the engine (the
/// re-entry guard in `SpeechTranscriber` backs this up).
///
/// The state machine is the source of truth for the overlay UI:
///   listening → safetyWindow → executing → success
///   listening → empty
///   (any) → error / permissionDenied
@Observable
@MainActor
final class VoiceCaptureViewModel {

    /// The auto-execute state machine (concept doc Section 4).
    enum State: Equatable {
        case listening          // A  — recording, InkOrb reactive, live transcript
        case safetyWindow       // A1 — "Got it", 1.5s escape hatch before execute
        case executing          // C  — AI processing
        case success            // D  — confirmation rows + auto-dismiss
        case empty              // E  — silence detected, no speech
        case permissionDenied   // F  — mic / speech permission denied
        case error(String)      // G  — transcription or AI failure (message)
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

    /// Success rows for State D — one per applied action.
    private(set) var successLabels: [String] = []

    /// Error/AI message surfaced in State G.
    private(set) var errorMessageText: String?

    /// Live transcript convenience (reads through to the transcriber). The
    /// overlay binds to this for State A; the finalized text is snapshotted
    /// into `finalizedTranscript` when listening stops.
    var transcript: String { transcriber.transcript }

    /// Normalized mic amplitude (0–1) for the InkOrb.
    var audioLevel: Float { transcriber.audioLevel }

    /// Snapshot of the transcript captured when listening stops (A → A1). This
    /// is what gets executed; the live `transcriber.transcript` is cleared on
    /// the next start so we can't rely on it past finalize.
    private(set) var finalizedTranscript: String = ""

    /// Swipe-to-dismiss is allowed only in the terminal states (concept doc
    /// Section 10). The overlay binds `interactiveDismissDisabled` to the
    /// inverse of this.
    var allowsInteractiveDismiss: Bool {
        switch state {
        case .listening, .safetyWindow, .executing: return false
        case .success, .empty, .permissionDenied, .error: return true
        }
    }

    // MARK: Private

    /// The overlay runs its own `ChatViewModel` so the AI execute path is
    /// identical to the chat surface (same streaming service + executor),
    /// without coupling to `ChatView`'s on-screen conversation.
    private let chat = ChatViewModel()

    private var silenceTimer: Timer?
    /// 1.5s silence window per the revised concept doc.
    private let silenceDelay: TimeInterval = 1.5
    /// 1.5s safety window before auto-execute.
    private let safetyWindowDelay: TimeInterval = 1.5

    private var safetyTask: Task<Void, Never>?
    private var executeTask: Task<Void, Never>?
    /// Awaits the async final transcript after a manual stop that raced the
    /// network (issue #151). Cancelled by teardown / restart.
    private var awaitFinalTask: Task<Void, Never>?
    /// Max time to wait for the async `…completed` after a manual stop before
    /// giving up. Comfortably covers the transcriber's own ~2s socket drain.
    private let finalTranscriptTimeout: TimeInterval = 2.5

    // MARK: Lifecycle

    /// Called when the overlay appears. Starts a fresh recording session.
    func begin() {
        successLabels = []
        errorMessageText = nil
        finalizedTranscript = ""
        // Reset to .listening SYNCHRONOUSLY. This VM is a single shared
        // instance, so after a prior capture `state` is still a terminal value
        // (e.g. .success). `startListening()` runs in a Task (one runloop
        // later), so without this the overlay's first render on re-open shows
        // the stale terminal state — which mounts the success auto-dismiss line
        // and schedules a 2s dismiss that closes the overlay right after it
        // opens (issue #151, second-open bug).
        state = .listening
        Task { await startListening() }
    }

    /// Start (or restart) recording — used by `begin()` and Try Again (E/G).
    /// The transcriber's own re-entry guard makes a redundant start a no-op.
    func startListening() async {
        cancelTimers()
        successLabels = []
        errorMessageText = nil
        finalizedTranscript = ""
        state = .listening

        // Permission gate up front so denial routes to State F, not the
        // generic error path (concept doc State F vs G).
        if Self.permissionDenied {
            state = .permissionDenied
            return
        }
        await transcriber.toggle()
        if !transcriber.isRecording {
            routeStartFailure()
        }
    }

    /// A transcriber error surfaced asynchronously while we were listening (most
    /// commonly a connection failure: the WebSocket never came up on a weak
    /// link, issue #151). The transcriber has already torn its socket down and
    /// flipped `isRecording` false, so there will be no transcript. Route the
    /// overlay to its error state (State G) with the friendly message rather
    /// than hanging in `.listening` forever. Only acts from the live "before
    /// finalize" states — once we're past finalize the execute path owns errors.
    func handleTranscriberError(_ message: String) {
        switch state {
        case .listening, .safetyWindow:
            cancelTimers()
            Self.log.info("transcriber error while pre-finalize → State G")
            errorMessageText = Self.stripTechnicalPrefix(message)
            state = .error(errorMessageText ?? "Something went wrong.")
        case .executing, .success, .empty, .permissionDenied, .error:
            // Past finalize (or already terminal): the execute path / existing
            // terminal state owns the UI. Don't override it.
            break
        }
    }

    /// Re-arm the 1.5s silence countdown. Called by the overlay on every
    /// transcript partial while in State A. Resets on each word; when it fires
    /// with a non-empty transcript we enter the safety window, with an empty
    /// one we go to State E.
    func scheduleSilenceFinalize() {
        guard state == .listening else { return }
        // Never arm on an empty transcript. With the OpenAI engine the
        // transcript is empty — and stays empty — WHILE the user is still
        // speaking (server VAD only emits text after a pause). The overlay
        // arms this on every transcript change, including the empty reset at
        // open, which fired the timer mid-speech and killed the session before
        // it captured anything ("stops as soon as it opens", issue #151). Arm
        // only once real text exists; server VAD's own turn detection is what
        // produces that text after the user pauses.
        guard !transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: silenceDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.onSilenceElapsed() }
        }
    }

    private func onSilenceElapsed() {
        guard state == .listening else { return }
        Self.log.info("silence timer fired")
        let text = transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            transcriber.stop()
            state = .empty
        } else {
            enterSafetyWindow()
        }
    }

    /// "Stop Now" (State A): skip the silence wait and finalize immediately.
    ///
    /// With server VAD the transcript arrives async (issue #151): if the user
    /// taps Stop before pausing, no `…completed` has landed yet and a
    /// synchronous snapshot would be empty. So when the snapshot is empty we
    /// commit (via `stop()`) and AWAIT the async final transcript before
    /// deciding between the safety window and State E, rather than racing the
    /// network. When the snapshot is already non-empty (the user paused first,
    /// so `…completed` landed) we proceed straight to the safety window.
    func stopNow() {
        guard state == .listening else { return }
        let text = transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            awaitFinalThenFinalize()
        } else {
            enterSafetyWindow()
        }
    }

    /// Stop the mic (commits + drains the socket) and wait for the async final
    /// transcript. Used by the manual-stop path that can race the network. If a
    /// non-empty transcript lands before the timeout we enter the safety
    /// window; otherwise State E (silence detected, no speech).
    private func awaitFinalThenFinalize() {
        cancelTimers()
        // Show the "Got it" safety window immediately so the UI isn't frozen
        // while we wait for the network, but DON'T snapshot/execute yet — the
        // safety countdown is (re)started once the real transcript lands.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        transcriber.stop() // commit + drain; transcript lands async
        state = .safetyWindow

        let baseline = transcriber.didFinalizeTranscript
        awaitFinalTask?.cancel()
        awaitFinalTask = Task { [finalTranscriptTimeout] in
            let deadline = Date().addingTimeInterval(finalTranscriptTimeout)
            // Poll for a finalize signal or non-empty transcript. Cheap: a few
            // 100ms ticks over at most ~2.5s, cancelled as soon as we resolve.
            while Date() < deadline {
                if Task.isCancelled { return }
                if transcriber.didFinalizeTranscript != baseline
                    || !transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if Task.isCancelled { return }
            let text = transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                state = .empty
            } else {
                // Snapshot the now-arrived transcript and start the real safety
                // countdown to auto-execute.
                finalizedTranscript = text
                Self.log.info("finalize snapshot (async after manual stop): len=\(text.count, privacy: .public)")
                startSafetyCountdown()
            }
        }
    }

    /// A → A1. Stop the mic, snapshot the (already-present) transcript, fire a
    /// light haptic, and start the 1.5s safety countdown that auto-executes
    /// unless cancelled. Used when the transcript is already non-empty (natural
    /// pause: `…completed` has landed). The racy manual-stop case goes through
    /// `awaitFinalThenFinalize()` instead.
    private func enterSafetyWindow() {
        cancelTimers()
        finalizedTranscript = transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.log.info("finalize snapshot (natural pause): len=\(self.finalizedTranscript.count, privacy: .public)")
        let snapshotFinalize = transcriber.didFinalizeTranscript
        transcriber.stop()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        state = .safetyWindow
        startSafetyCountdown()
        // If the snapshot is still in Urdu script, the Devanagari-normalized
        // final may land during the socket drain (issue #151). Watch for the
        // next `…completed` within the safety window and adopt the normalized
        // text so both the preview and the parsed input use Hindi, not Urdu.
        // Only for the Urdu case — English / Devanagari snapshots are final.
        if HindiScriptNormalizer.containsPersoArabic(finalizedTranscript) {
            awaitFinalTask?.cancel()
            awaitFinalTask = Task { [safetyWindowDelay] in
                let deadline = Date().addingTimeInterval(safetyWindowDelay)
                while Date() < deadline {
                    if Task.isCancelled { return }
                    if transcriber.didFinalizeTranscript != snapshotFinalize {
                        let updated = transcriber.transcript
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !updated.isEmpty { finalizedTranscript = updated }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    /// Start (or restart) the 1.5s safety countdown that auto-executes
    /// `finalizedTranscript` unless cancelled. Assumes `state == .safetyWindow`
    /// and `finalizedTranscript` is set.
    private func startSafetyCountdown() {
        safetyTask?.cancel()
        safetyTask = Task { [safetyWindowDelay] in
            try? await Task.sleep(nanoseconds: UInt64(safetyWindowDelay * 1_000_000_000))
            if Task.isCancelled { return }
            execute()
        }
    }

    /// A1 → C. Run the finalized transcript through the AI pipeline, then D or G.
    private func execute() {
        let input = finalizedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { state = .empty; return }
        state = .executing
        successLabels = []
        errorMessageText = nil

        executeTask = Task {
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
            if applied.isEmpty {
                successLabels = ["Message sent"]
            } else {
                successLabels = applied.map(Self.successLabel(for:))
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            state = .success
        }
    }

    /// Try Again on an AI error (State G) — re-run the same transcript.
    func retryExecute() {
        guard !finalizedTranscript.isEmpty else {
            Task { await startListening() }
            return
        }
        execute()
    }

    /// Cancel from any state with no side effect. Best-effort cancels an
    /// in-flight AI task in State C. This is the single teardown path, called
    /// from the `.fullScreenCover` `onDismiss` regardless of how it closed.
    func teardown() {
        cancelTimers()
        safetyTask?.cancel(); safetyTask = nil
        executeTask?.cancel(); executeTask = nil
        awaitFinalTask?.cancel(); awaitFinalTask = nil
        transcriber.stop()
    }

    /// Open the system Settings app (State F).
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: Helpers

    private func cancelTimers() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        safetyTask?.cancel()
        safetyTask = nil
        awaitFinalTask?.cancel()
        awaitFinalTask = nil
    }

    private func routeStartFailure() {
        if Self.permissionDenied {
            state = .permissionDenied
        } else if let msg = transcriber.errorMessage {
            errorMessageText = msg
            state = .error(msg)
        }
        // Otherwise (e.g. SFSpeech "no speech" already silenced) stay in
        // .listening; the silence timer routes to State E.
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

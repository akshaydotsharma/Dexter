import Foundation
import os

/// Thin WebSocket client for OpenAI's Realtime transcription API (issue #151).
///
/// Streams PCM16 microphone audio to OpenAI and surfaces live transcript
/// deltas + final transcripts back to `SpeechTranscriber`. The session
/// `language` is intentionally OMITTED so the model auto-detects Hindi vs
/// English per utterance — pinning it to `hi` forced English speech to be
/// (mis)transcribed as Hindi, producing empty/garbled results (issue #151).
/// Script normalization (Urdu → Devanagari) happens downstream in
/// `SpeechTranscriber` via `HindiScriptNormalizer`, so we don't rely on the STT
/// layer to pick a script it can't reliably control for live Hindustani speech.
///
/// ### Doc-confirmed Realtime API shape (platform/developers.openai.com, GA)
///
/// - **Connect**: `wss://api.openai.com/v1/realtime?intent=transcription`
///   Header: `Authorization: Bearer <OPENAI_API_KEY>`. Native
///   `URLSessionWebSocketTask` can set request headers (unlike browsers), so
///   bearer auth works directly. No `OpenAI-Beta` header is required on the GA
///   endpoint.
/// - **Configure** (client → server), event `session.update`:
///   ```json
///   {
///     "type": "session.update",
///     "session": {
///       "type": "transcription",
///       "audio": {
///         "input": {
///           "format": { "type": "audio/pcm", "rate": 24000 },
///           "transcription": { "model": "gpt-4o-mini-transcribe" },
///           "turn_detection": { "type": "server_vad", "silence_duration_ms": 700 }
///         }
///       }
///     }
///   }
///   ```
///   `transcription.language` is OMITTED → the model auto-detects the spoken
///   language (Hindi or English) per utterance. Script normalization (Urdu →
///   Devanagari) is handled downstream in `SpeechTranscriber`.
///   `turn_detection: server_vad` is REQUIRED for transcription to happen at
///   all. Empirically verified against the live API: with `turn_detection:
///   null` the server emits ZERO deltas while audio streams and only produces
///   a transcript after `input_audio_buffer.commit` — and our old `finish()`
///   cancelled the socket the instant it committed, so the post-commit
///   transcript was always discarded (the "transcription not working" bug).
///   With `server_vad` the server emits `speech_started`, then `speech_stopped`
///   ~700ms after the user pauses, then the `…transcription.delta` stream and
///   `…transcription.completed` (~0.5s after `speech_stopped`). So the UX is
///   "text appears shortly after the user pauses", NOT word-by-word during
///   speech — this transcription model does not stream mid-speech.
/// - **Send audio** (client → server), event `input_audio_buffer.append` with
///   base64-encoded PCM16: `{ "type": "input_audio_buffer.append", "audio": "<b64>" }`.
/// - **Commit** (client → server) on manual stop, to force-close any open
///   segment: `{ "type": "input_audio_buffer.commit" }`. After committing we
///   KEEP the socket open until the resulting `…completed` arrives (or a short
///   timeout), so the final transcript is never discarded.
/// - **Receive** (server → client):
///   - `input_audio_buffer.speech_started` / `…speech_stopped` — VAD markers.
///   - `conversation.item.input_audio_transcription.delta` — incremental
///     `delta` text (NOT cumulative; we append).
///   - `conversation.item.input_audio_transcription.completed` — authoritative
///     full `transcript` for the utterance.
///   - `error` — `{ "type": "error", "error": { "message": "…" } }`.
///
/// The legacy beta shape (`transcription_session.update` +
/// `input_audio_transcription` + `OpenAI-Beta: realtime=v1`) is also accepted
/// by older accounts; we send the GA shape, which the current docs document.
///
/// `actor` so all socket state is serialized off the main actor. The mic tap
/// (background queue) calls `appendAudio(_:)` and the main actor calls
/// `connect` / `finish` — the actor keeps them race-free.
actor OpenAIRealtimeTranscriber {

    /// Voice-pipeline diagnostics (issue #151). Lets the on-device socket flow
    /// (the one layer that can't be exercised off-device) be traced on a single
    /// tap via Console.app, filtering on this subsystem. Terse, never logs the
    /// API key, never logs in a hot loop (deltas are logged by count only).
    private static let log = Logger(
        subsystem: "com.akshaysharma.personaldashboard.voice",
        category: "OpenAIRealtimeTranscriber"
    )

    /// Count of transcription deltas received this session, so we log "N deltas"
    /// once rather than logging every delta (which arrives in a hot stream).
    private var deltaCount = 0

    enum TranscriberError: Error, LocalizedError {
        case badURL
        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid transcription endpoint."
            }
        }
    }

    /// User-facing copy for any failure to bring the socket up (never connected,
    /// real transport error, or watchdog timeout). Deliberately non-technical:
    /// the underlying CFNetwork code / NSError reason is logged, not shown.
    /// `SpeechTranscriber` reads this to recognise a connection failure (vs. a
    /// transient server error) and tear the session down so `isRecording` flips.
    static let connectionFailedMessage =
        "Couldn't reach voice transcription. Check your connection and try again."

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    /// True once the socket has actually come up — either the
    /// `URLSessionWebSocketDelegate` reported `didOpenWithProtocol` OR the first
    /// server event (`session.updated`) arrived. The watchdog and the
    /// `didCompleteWithError` classifier both read this to tell "never connected"
    /// from "failed after connecting".
    private var didConnect = false

    /// Cancels the connection watchdog once we connect (or tear down). The
    /// watchdog fires `connectionFailedMessage` if neither "opened" nor
    /// `session.updated` happens within `connectTimeoutSeconds`.
    private var watchdogTask: Task<Void, Never>?
    /// How long to wait for the socket to come up before declaring a connection
    /// failure. On a weak/cellular link the socket can sit in "connecting"
    /// indefinitely; this is the upper bound the user waits before a clear
    /// message instead of an indefinite hang.
    private let connectTimeoutSeconds: UInt64 = 8
    /// Set false only when we actually tear the socket down (drain complete or
    /// timeout) so a late receive-loop iteration doesn't reopen the read or
    /// report a spurious error after we intentionally closed. NOTE: this stays
    /// TRUE through `finish()` — we keep reading after a commit so the
    /// post-commit `…completed` is delivered, not discarded.
    private var isActive = false

    /// True once `finish()` has committed and we're waiting for the final
    /// `…completed` (or the drain timeout) before closing. Audio appends are
    /// rejected in this window, but receives keep flowing.
    private var isDraining = false

    /// Set when a `…completed` is delivered after a manual commit, so the drain
    /// timeout knows the result already landed and just needs to close.
    private var didReceiveFinalAfterCommit = false

    /// True when audio has been appended that the server has NOT yet committed.
    /// With `server_vad` the server AUTO-commits each segment on `speech_stopped`,
    /// so after a natural pause the buffer is already empty. `finish()` uses this
    /// to avoid a REDUNDANT `input_audio_buffer.commit` on an empty buffer, which
    /// the server rejects with a benign "buffer too small" error (issue #151).
    private var hasUncommittedAudio = false

    /// Full (non-mini) transcription model — materially better at Hindi/English
    /// language identification than `gpt-4o-mini-transcribe`, which is what
    /// makes spoken Hindi land in Devanagari rather than Urdu more reliably at
    /// the source (issue #151).
    private let transcriptionModel = "gpt-4o-transcribe"
    /// Steers the transcription without hard-forcing a language (which would
    /// break English detection). Biases Hindi output toward Devanagari and
    /// keeps English in the Latin alphabet. The downstream normalizer still
    /// catches any residual Urdu, so this only reduces how often it's needed.
    private let transcriptionPrompt =
        "The audio is in Hindi or English. Write Hindi in Devanagari script "
        + "(for example: नमस्ते, कल, बजे), never in Urdu or Perso-Arabic script. "
        + "Write English in the Latin alphabet."
    private let sampleRate = 24_000
    /// Server VAD silence threshold. The server finalizes a turn this long
    /// after the user stops speaking.
    private let vadSilenceMs = 700
    /// Max time to wait after a manual commit for the final `…completed` before
    /// giving up and closing the socket. The running `transcript` (built from
    /// deltas) is the fallback if this elapses.
    private let drainTimeoutSeconds: UInt64 = 2

    // Callbacks (set on connect). Marked @Sendable; they hop to @MainActor
    // inside `SpeechTranscriber`.
    private var onDelta: (@Sendable (String) -> Void)?
    private var onCompleted: (@Sendable (String) -> Void)?
    private var onError: (@Sendable (String) -> Void)?

    /// Open the socket, send the transcription session config, and start the
    /// receive loop. Throws only on a bad URL — the actual socket open is
    /// async and surfaces failures through `onError`.
    func connect(
        apiKey: String,
        onDelta: @escaping @Sendable (String) -> Void,
        onCompleted: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) throws {
        self.onDelta = onDelta
        self.onCompleted = onCompleted
        self.onError = onError

        guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
            Self.log.error("connect failed: bad URL")
            throw TranscriberError.badURL
        }

        deltaCount = 0
        didConnect = false
        // Log the endpoint, never the bearer token.
        Self.log.info("socket connect attempt: \(url.absoluteString, privacy: .public)")
        // idevicesyslog-visible lifecycle trace (os.Logger .info lines are NOT
        // relayed to idevicesyslog). Terse, never logs the key or transcript.
        NSLog("[voice] ws connect %@", url.absoluteString)

        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let cfg = URLSessionConfiguration.default
        // A delegate gives us `didOpenWithProtocol` (socket actually opened) and
        // `didCompleteWithError` (real failure, which we classify as cancellation
        // vs. genuine). The forwarder is nonisolated and hops back into the actor.
        let forwarder = DelegateForwarder()
        let session = URLSession(configuration: cfg, delegate: forwarder, delegateQueue: nil)
        let task = session.webSocketTask(with: req)
        forwarder.owner = self
        self.session = session
        self.task = task
        self.isActive = true

        task.resume()

        // Send the transcription session configuration.
        sendSessionConfig()

        // Start reading server events.
        receiveLoop()

        // Arm the connection watchdog. Cancelled on connect (didOpen /
        // session.updated) or teardown.
        startWatchdog()
    }

    /// Arm the connection watchdog: if neither the socket "opens" nor a first
    /// server event lands within `connectTimeoutSeconds`, surface the friendly
    /// connection-failed message and tear down. No-op if we connect first.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [connectTimeoutSeconds] in
            try? await Task.sleep(nanoseconds: connectTimeoutSeconds * 1_000_000_000)
            if Task.isCancelled { return }
            self.watchdogFired()
        }
    }

    /// The watchdog elapsed without the socket coming up. Treat as a connection
    /// failure: report the friendly message once, then tear down cleanly so the
    /// caller lands in a clean error/empty state (not stuck "listening").
    private func watchdogFired() {
        guard isActive, !didConnect else { return }
        Self.log.error("connection watchdog fired: socket never came up in \(self.connectTimeoutSeconds, privacy: .public)s")
        NSLog("[voice] error: connect timeout (%llus, socket never opened)", connectTimeoutSeconds)
        reportError(Self.connectionFailedMessage)
        // Mark inactive BEFORE closing so the in-flight receive loop / send
        // completions classify their resulting errors as our cancellation and
        // stay silent.
        isActive = false
        closeSocket()
    }

    /// Mark the socket as connected and cancel the watchdog. Called from the
    /// delegate's `didOpenWithProtocol` and from the first server event. Idempotent.
    private func markConnected(reason: String) {
        guard !didConnect else { return }
        didConnect = true
        watchdogTask?.cancel()
        watchdogTask = nil
        Self.log.info("socket connected (\(reason, privacy: .public))")
        NSLog("[voice] ws opened (%@)", reason)
    }

    /// Delegate callback (off-actor): the WebSocket handshake completed.
    fileprivate func socketDidOpen() {
        markConnected(reason: "didOpenWithProtocol")
    }

    /// Delegate callback (off-actor): the underlying task finished. Classify the
    /// error: a cancellation (-999 / our own teardown) is suppressed; a genuine
    /// transport failure before we connected is a connection failure.
    fileprivate func socketDidComplete(error: Error?) {
        if let error {
            Self.log.error("task completed with error: \(error.localizedDescription, privacy: .public)")
        } else {
            Self.log.info("task completed cleanly")
        }
        // A clean completion, or one that arrives after we'd already connected
        // and drained, needs no user-facing error.
        if didConnect || !isActive {
            NSLog("[voice] ws closed")
            return
        }
        // We never connected and we're still active → genuine connection
        // failure (unless it's a cancellation, which `isCancellation` filters out).
        if Self.isCancellation(error) {
            Self.log.debug("task completed via cancellation before connect — suppressed")
            NSLog("[voice] ws closed (cancelled)")
            isActive = false
            closeSocket()
            return
        }
        let classified = error?.localizedDescription ?? "no error object"
        Self.log.error("connection failed before open: \(classified, privacy: .public)")
        NSLog("[voice] error: connection failed before open (%@)", classified)
        reportError(Self.connectionFailedMessage)
        isActive = false
        closeSocket()
    }

    /// True for errors we consider intentional/cancellation rather than a
    /// genuine transport failure: `NSURLErrorCancelled` (-999, what a torn-down
    /// or never-connected socket reports), `CancellationError`, and `nil`.
    private static func isCancellation(_ error: Error?) -> Bool {
        guard let error else { return true }
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        return false
    }

    /// True for the benign empty-buffer commit error the server returns when a
    /// commit lands on an already-committed (empty) buffer. With server_vad the
    /// server auto-commits each segment on pause, so a stray/redundant commit is
    /// rejected here. Matched by substring across the known phrasings.
    private static func isBenignCommitError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("buffer too small")
            || lower.contains("input_audio_buffer_commit_empty")
            || lower.contains("expected at least 100ms")
    }

    /// Append one chunk of PCM16 audio (already 24kHz mono) as base64. Ignored
    /// once we've started draining (post-commit) so we don't reopen a segment.
    func appendAudio(_ pcm16: Data) {
        guard isActive, !isDraining else { return }
        let b64 = pcm16.base64EncodedString()
        // Mark that there's uncommitted audio in the buffer; cleared when the
        // server auto-commits on `speech_stopped` or when we commit in `finish()`.
        hasUncommittedAudio = true
        send([
            "type": "input_audio_buffer.append",
            "audio": b64
        ])
    }

    /// Manual stop ("Stop Now" / inline-mic stop, before a natural pause).
    ///
    /// Force-close any open segment with a commit, then KEEP the socket open
    /// and `isActive` true until the resulting `…completed` arrives (delivered
    /// via `onCompleted`) or `drainTimeoutSeconds` elapses — only THEN close.
    /// This is the fix for the discarded-transcript bug: the old code cancelled
    /// the socket the instant it committed, so the post-commit transcript was
    /// thrown away every time.
    ///
    /// In the natural-pause case server_vad auto-finalizes and `…completed`
    /// arrives BEFORE any manual `finish()`, so this path is only hit on an
    /// explicit stop. Idempotent: a second call while draining is a no-op.
    func finish() {
        guard isActive, !isDraining else { return }
        isDraining = true
        didReceiveFinalAfterCommit = false
        // Only commit when there's uncommitted audio (a true manual "Stop Now"
        // before the VAD pause). After a natural pause server_vad has already
        // committed the segment and the buffer is empty — a redundant commit
        // triggers the benign "buffer too small" server error (issue #151), so
        // skip it and go straight to the drain/close.
        if hasUncommittedAudio {
            hasUncommittedAudio = false
            send(["type": "input_audio_buffer.commit"])
        } else {
            Self.log.info("finish: skipping redundant commit (buffer already committed by server_vad)")
            NSLog("[voice] finish: skip redundant commit (buffer empty)")
        }

        // Wait for the final transcript, but don't hang forever. The Task
        // inherits this actor's isolation, so `drainTimedOut()` is a same-actor
        // call (no `await` needed — that was the spurious-await warning).
        Task { [drainTimeoutSeconds] in
            try? await Task.sleep(nanoseconds: drainTimeoutSeconds * 1_000_000_000)
            self.drainTimedOut()
        }
    }

    /// Close the socket once the post-commit `…completed` has been delivered, or
    /// after a connection failure / watchdog timeout. Tears down the task and
    /// session and cancels the watchdog. Safe to call when already inactive
    /// (the connection-failure paths flip `isActive` false BEFORE calling here,
    /// so they can run teardown without re-reporting; hence no `isActive` guard).
    private func closeSocket() {
        Self.log.info("socket close (deltas this session: \(self.deltaCount, privacy: .public))")
        NSLog("[voice] ws closed")
        isActive = false
        isDraining = false
        watchdogTask?.cancel()
        watchdogTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    /// The drain timeout fired. If the final transcript already arrived we've
    /// likely closed already; otherwise close now and let the caller fall back
    /// to the running delta-built transcript.
    private func drainTimedOut() {
        guard isDraining else { return }
        Self.log.info("drain timeout: closing without a post-commit completed (final lands from running deltas)")
        closeSocket()
    }

    // MARK: Private

    private func sendSessionConfig() {
        let config: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": sampleRate
                        ],
                        // `language` intentionally OMITTED: the model
                        // auto-detects Hindi vs English per utterance. Pinning
                        // it to `hi` forced English audio to transcribe as
                        // Hindi (empty/garbled), and script (Urdu vs Devanagari)
                        // is normalized downstream, not here (issue #151).
                        "transcription": [
                            "model": transcriptionModel,
                            "prompt": transcriptionPrompt
                        ],
                        // Server VAD is REQUIRED: with `turn_detection: null`
                        // the server emits no deltas and only transcribes after
                        // a manual commit. server_vad makes the server finalize
                        // ~700ms after the user pauses and stream the result.
                        "turn_detection": [
                            "type": "server_vad",
                            "silence_duration_ms": vadSilenceMs
                        ]
                    ]
                ]
            ]
        ]
        send(config)
    }

    private func send(_ object: [String: Any]) {
        guard let task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return }
        task.send(.string(json)) { [weak self] error in
            guard let error else { return }
            Task { await self?.handleSendFailure(error) }
        }
    }

    /// A queued send failed. On a weak/torn-down socket the session-config and
    /// audio appends fail with `-999` (NSURLErrorCancelled) because the socket
    /// never finished connecting or has been cancelled — surfacing that as a
    /// user error is exactly the spurious "cancelled" bug (issue #151). Suppress
    /// any cancellation, or any failure once we're inactive/draining (our own
    /// teardown). Report only a genuine transport failure on a live, non-draining
    /// socket; the watchdog covers the never-connected case with a clearer message.
    private func handleSendFailure(_ error: Error) {
        if Self.isCancellation(error) || !isActive || isDraining {
            Self.log.debug("send failure suppressed (cancellation or inactive): \(error.localizedDescription, privacy: .public)")
            return
        }
        Self.log.error("send failure on live socket: \(error.localizedDescription, privacy: .public)")
        NSLog("[voice] error: send failed (%@)", error.localizedDescription)
        reportError(error.localizedDescription)
    }

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            Task { await self.handleReceive(result) }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        guard isActive else { return }
        switch result {
        case .failure(let error):
            // A receive failure on a torn-down or never-connected socket is
            // NSURLErrorCancelled (-999) — that's our own teardown, not a user
            // error (issue #151). Suppress cancellations and any failure while
            // inactive/draining; report only a genuine transport failure on a
            // live socket. The watchdog handles the never-connected case.
            if Self.isCancellation(error) || !isActive || isDraining {
                Self.log.debug("receive failure suppressed (cancellation or inactive): \(error.localizedDescription, privacy: .public)")
            } else {
                Self.log.error("receive loop failure (socket dead): \(error.localizedDescription, privacy: .public)")
                NSLog("[voice] error: receive failed (%@)", error.localizedDescription)
                reportError(error.localizedDescription)
            }
            // Socket is dead — stop looping.
            isActive = false
        case .success(let message):
            switch message {
            case .string(let text):
                parseServerEvent(text)
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) {
                    parseServerEvent(text)
                }
            @unknown default:
                break
            }
            // Keep reading.
            receiveLoop()
        }
    }

    private func parseServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else { return }

        switch type {
        case "session.updated", "transcription_session.updated":
            Self.log.info("session.updated received (transcription config accepted)")
            NSLog("[voice] session.updated")
            // First server event is the fallback "connected" signal (covers the
            // case where the delegate's didOpen is missed/late). Cancels the watchdog.
            markConnected(reason: "session.updated")
        case "input_audio_buffer.speech_started":
            Self.log.info("speech_started")
            NSLog("[voice] speech_started")
        case "input_audio_buffer.speech_stopped":
            // server_vad has auto-committed this segment — the buffer is now
            // empty, so a subsequent manual commit would be redundant.
            hasUncommittedAudio = false
            Self.log.info("speech_stopped (segment auto-committed by server_vad)")
            NSLog("[voice] speech_stopped")
        case "conversation.item.input_audio_transcription.delta",
             "transcription.delta":
            if let delta = root["delta"] as? String, !delta.isEmpty {
                // Hot path — don't log per delta; count and log the total at
                // completed / close.
                deltaCount += 1
                onDelta?(delta)
            }
        case "conversation.item.input_audio_transcription.completed",
             "transcription.completed":
            if let full = root["transcript"] as? String {
                // Log length only, never the transcript text itself.
                Self.log.info("completed transcript (len=\(full.count, privacy: .public), deltas=\(self.deltaCount, privacy: .public))")
                NSLog("[voice] completed len=%d deltas=%d", full.count, deltaCount)
                onCompleted?(full)
            }
            // If this arrived after a manual commit, the drain is done — close
            // now rather than waiting out the timeout. (In the natural-pause /
            // server_vad case isDraining is false and the socket stays open
            // for the next utterance.)
            if isDraining {
                didReceiveFinalAfterCommit = true
                closeSocket()
            }
        case "error":
            if let err = root["error"] as? [String: Any],
               let message = err["message"] as? String {
                // Suppress the benign empty-buffer commit error: with server_vad
                // the server auto-commits on pause, and any stray commit on the
                // now-empty buffer is rejected with "buffer too small". It's not
                // a real failure and must never surface to the user (issue #151).
                if Self.isBenignCommitError(message) {
                    Self.log.info("suppressing benign empty-commit error: \(message, privacy: .public)")
                    NSLog("[voice] suppressed benign commit error")
                    break
                }
                Self.log.error("server error event: \(message, privacy: .public)")
                NSLog("[voice] error: server event (%@)", message)
                reportError(message)
            } else {
                Self.log.error("server error event (no message)")
                NSLog("[voice] error: server event (no message)")
                reportError("Transcription error.")
            }
        default:
            // Ignore session.created, buffer committed events, etc.
            break
        }
    }

    private func reportError(_ message: String) {
        onError?(message)
    }
}

/// Bridges `URLSessionWebSocketDelegate` callbacks (delivered on URLSession's
/// delegate queue, off the actor) into the `OpenAIRealtimeTranscriber` actor.
///
/// `URLSession` holds the delegate strongly until `invalidateAndCancel()` (which
/// `closeSocket()` calls), so this forwarder lives exactly as long as the socket
/// session. `owner` is `weak` to avoid a retain cycle with the actor that owns
/// the session that owns this delegate.
private final class DelegateForwarder: NSObject, URLSessionWebSocketDelegate {
    weak var owner: OpenAIRealtimeTranscriber?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let owner = self.owner
        Task { await owner?.socketDidOpen() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let owner = self.owner
        Task { await owner?.socketDidComplete(error: error) }
    }
}

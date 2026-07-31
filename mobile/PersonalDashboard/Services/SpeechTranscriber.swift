import AVFoundation
import Foundation
import Observation
import os
import Speech

/// Speech-to-text for the chat input bar + full-screen voice capture overlay
/// (issues #83, #150, #151).
///
/// Two engines behind ONE unchanged public surface:
///
///   • **OpenAI Realtime transcription** (preferred, issue #151). Streams mic
///     audio over a WebSocket to OpenAI and gets back live transcript deltas.
///     Auto-detects language (Hindi / English / Hinglish) because we omit the
///     `language` field. Used whenever `AppConfig.openAIAPIKey` is set.
///
///   • **On-device `SFSpeechRecognizer`** (fallback, en-US). Used when no
///     OpenAI key is configured at runtime, so the app stays usable offline /
///     keyless. This is the original issue-#83 path, kept verbatim as the
///     else-branch.
///
/// The choice is made per `start()` based on the key. Both engines feed the
/// SAME `transcript` / `isRecording` / `audioLevel` surface, so the overlay,
/// `VoiceCaptureViewModel`, `ChatView`, and `ChatInputBar` work unchanged:
///   - `audioLevel` is always computed from the local mic tap (`normalizedRMS`
///     + `publishLevel`), independent of which engine transcribes — reused
///     verbatim from #150.
///   - `transcript` behaves per engine. SFSpeech updates it incrementally
///     (the system hands back the full running string each partial). The
///     OpenAI engine reveals it only ONCE per utterance, on the normalized
///     `…completed`. Either way it holds the full text by the time
///     `VoiceCaptureViewModel` snapshots it on silence.
///   - Raw OpenAI deltas go to `provisionalText`, NEVER `transcript` (issue
///     #429). #151 discarded them outright because pre-normalization they can
///     be in Urdu script and the correction read as a flash; keeping them in a
///     separate, visibly-unsettled channel is what made surfacing them safe.
///     `ChatView` still mirrors only `transcript`, so the inline chat bar is
///     unaffected by this and never sees pre-normalization text.
///   - The OpenAI engine uses server VAD: each pause is finalized as its own
///     `…completed`, and utterances are accumulated (so multi-phrase dictation
///     in one recording doesn't lose earlier text). A manual `stop()` commits
///     any open segment and drains the socket for the final transcript.
@Observable
@MainActor
final class SpeechTranscriber {

    /// Voice-pipeline diagnostics (issue #151). Same subsystem as the socket
    /// client so a single Console.app filter shows the whole flow end to end.
    private static let log = Logger(
        subsystem: "com.akshaysharma.personaldashboard.voice",
        category: "SpeechTranscriber"
    )

    /// One-shot flag so we log the first converted PCM16 chunk size once per
    /// session rather than on every audio buffer (the tap fires continuously).
    private var loggedFirstChunk = false

    /// One-shot flag so we log only the FIRST transcript delta (marks when the
    /// stream starts producing text) rather than every delta (a hot stream).
    private var loggedFirstDelta = false

    /// Live partial transcript while recording. For the OpenAI engine this is
    /// built up by appending each `…transcription.delta` (deltas are
    /// incremental, not cumulative) and replaced by the authoritative
    /// `…transcription.completed` transcript when it arrives. For the SFSpeech
    /// fallback it is replaced wholesale on every partial (the system already
    /// returns the full running transcript per callback).
    ///
    /// NOTE (issue #151): the OpenAI transcript arrives ASYNC — with server VAD
    /// the `…completed` lands ~0.5s after the user pauses, and on a manual stop
    /// it lands shortly after the commit. So `transcript` keeps updating from
    /// the socket even after `stop()` has flipped `isRecording` false, until
    /// the socket drains. Callers must NOT assume `transcript` is final the
    /// instant they call `stop()`; observe `didFinalizeTranscript` (or the
    /// `transcript` itself) instead of snapshotting synchronously.
    private(set) var transcript: String = ""

    /// Monotonic counter bumped each time a non-empty authoritative transcript
    /// is delivered (OpenAI `…completed`, or SFSpeech final). `@Observable`
    /// callers can watch this to finalize off the transcript actually being
    /// present rather than racing a synchronous snapshot at stop time. The
    /// counter (vs. a Bool) guarantees a distinct value per finalize so
    /// back-to-back finals each register as a change.
    private(set) var didFinalizeTranscript: Int = 0

    /// True between a successful start and the corresponding stop. The
    /// chat view uses this both to mirror `transcript` into the input
    /// field and to swap the mic icon for a recording indicator.
    private(set) var isRecording: Bool = false

    /// Fired once per finalized-and-normalized utterance (issue #156). server_vad
    /// segments each pause into its own `…completed`; the continuous voice
    /// overlay consumes these as DISCRETE captures so it can execute them one at
    /// a time. The payload is the same Devanagari-normalized text that gets
    /// folded into `committedTranscript`, so callers of this stream never see raw
    /// Urdu. Set by `VoiceCaptureViewModel` for the duration of a session; nil
    /// for the inline chat bar (which only reads the accumulated `transcript`).
    /// Invoked on the @MainActor.
    var onUtteranceFinalized: ((String) -> Void)?

    /// Surfaced inline above the input bar when permission is denied or
    /// the audio engine fails. Cleared on the next successful `toggle()`.
    var errorMessage: String?

    /// Normalized microphone amplitude (0.0–1.0), computed as RMS of each
    /// audio buffer in the input tap, mapped from a -40dBFS floor, and
    /// low-pass filtered (rolling average over the last 4 frames) so it
    /// doesn't strobe. Drives the voice-capture waveform (issues #150, #429).
    /// Resets to 0 on stop. No extra permission needed — it reads the same
    /// buffer the recognizer already taps. Independent of the transcription
    /// engine; computed identically for OpenAI and SFSpeech paths.
    private(set) var audioLevel: Float = 0

    /// Short rolling history of `audioLevel`, written on every metering frame
    /// (issue #429). The voice overlay's waveform and aurora both read delayed
    /// taps off this, which is what makes energy ripple outward through the bars
    /// and the background surge on the same rhythm rather than in lockstep.
    ///
    /// Owned here rather than in the view layer because the audio tap is the
    /// only thing that knows when a new sample exists; sampling it from a
    /// SwiftUI `onChange` starved the buffer and pinned the bars at rest.
    ///
    /// `@ObservationIgnored` is REQUIRED, not an optimisation. This is written
    /// ~47 times a second. Observed, every write invalidated every view reading
    /// it, so the whole voice overlay (including five full-screen blurred
    /// gradients) re-rendered at 47 Hz on top of its own 30 Hz timelines. The
    /// main thread saturated the moment audio streamed continuously and SwiftUI
    /// dropped frames, which on device looked like the waveform working at the
    /// start of a sentence, freezing for the rest of it, then recovering the
    /// instant speech stopped.
    ///
    /// Consumers must POLL this from a `TimelineView` tick rather than observe
    /// it. That is the correct shape for animation data anyway: the display
    /// drives the sampling rate, not the microphone.
    @ObservationIgnored private(set) var levelTrace = VoiceLevelTrace()

    // MARK: Live capture signals (issue #429)

    /// Unsettled text for the utterance currently being transcribed, built by
    /// appending each `…transcription.delta`. Rendered muted by the voice
    /// overlay and replaced by the normalized `…completed` (which lands in
    /// `transcript`) a moment later.
    ///
    /// Deliberately NOT folded into `transcript`. Two reasons, both load-bearing:
    ///
    /// 1. `ChatView` mirrors `transcript` straight into the chat input field.
    ///    Putting raw deltas there would type pre-normalization text (possibly
    ///    Urdu script) into the user's message.
    /// 2. A delta is not authoritative. Keeping the two apart is what lets the
    ///    overlay render "provisional" and "settled" as visibly different
    ///    states, which is what makes the Urdu→Devanagari correction read as
    ///    the text resolving rather than as a glitch (the reason deltas were
    ///    suppressed outright before this issue).
    ///
    /// Cleared when the utterance finalizes and on stop.
    private(set) var provisionalText: String = ""

    /// True between server VAD's `speech_started` and `speech_stopped`.
    ///
    /// This is the only signal that arrives WHILE the user is talking:
    /// `gpt-4o-transcribe` does not transcribe mid-utterance, so text can't
    /// carry live feedback. Unlike `audioLevel` this is voice-gated by the
    /// server, so a door slam won't trip it. Always false on the on-device
    /// engine, which has no equivalent marker.
    private(set) var isSpeechDetected: Bool = false

    /// When the last `speech_stopped` landed, i.e. when the VAD silence window
    /// started. The overlay derives its countdown from this. Nil while speech
    /// is active or before the first utterance.
    private(set) var silenceStartedAt: Date?

    /// How long server VAD waits after speech stops before finalizing a turn.
    /// Mirrors `OpenAIRealtimeTranscriber.vadSilenceMs` so the countdown the
    /// user sees is the real deadline rather than a guess. Kept in sync by
    /// `SpeechTranscriberTests.testVADWindowMatchesSocketConfig`.
    static let vadSilenceWindow: TimeInterval = 0.7

    /// True once the transcription socket is confirmed up. The overlay holds a
    /// "Connecting" state until this flips, so the status never claims to be
    /// listening while the WebSocket is still coming up. Always true
    /// immediately for the on-device engine, which has no socket.
    private(set) var isConnected: Bool = false

    // MARK: Private state

    /// Rolling window of the last few normalized RMS readings for the
    /// low-pass filter. Mutated on the audio tap's background queue, read +
    /// averaged there too; the averaged value is hopped to the main actor for
    /// publishing.
    private var levelWindow: [Float] = []
    private let levelWindowSize = 4

    /// Which engine the current (or most recent) session is using. Decided in
    /// `start()` so `stop()` tears down the right one.
    private enum Engine { case openAI, onDevice }
    private var engine: Engine = .onDevice

    // -- On-device (SFSpeech) state --
    private let recognizer: SFSpeechRecognizer? = {
        // Force en-US — `.dictation` taskHint plus on-device model is best
        // tuned here. Falling back to the user's locale is fine in theory
        // but on-device support varies by language and silently degrades
        // to server recognition (which we explicitly disallow).
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// End-of-utterance debounce for the on-device engine (issue #156). SFSpeech
    /// has NO VAD segmentation — it runs one continuous `recognitionTask` and only
    /// hands back a final on `endAudio()`. To make the on-device path fire
    /// `onUtteranceFinalized` per pause like the OpenAI server_vad path does, we
    /// synthesize the segmentation: when the recognized text stops changing for
    /// this long, we treat the pause as an utterance boundary. Slightly longer
    /// than OpenAI's 700ms server-VAD window because the on-device partials update
    /// less smoothly, so a shorter window would clip mid-phrase.
    private let onDeviceSilenceDebounce: TimeInterval = 0.9

    /// The armed silence timer for the on-device engine. Re-armed on every partial
    /// that carries new text; fires `finalizeOnDeviceUtterance()` when it elapses.
    /// Cancelled on every new partial and on `stop()`.
    private var onDeviceSilenceTimer: Task<Void, Never>?

    // -- OpenAI Realtime state --
    private let openAI = OpenAIRealtimeTranscriber()
    /// Finalized (script-normalized) utterances for the current OpenAI session,
    /// joined with spaces. server_vad finalizes each pause as its own
    /// `…completed`, so one recording can yield several; accumulating here means
    /// a later utterance never clobbers an earlier one — the fix for the inline
    /// transcript "disappearing" mid-session (issue #151).
    private var committedTranscript: String = ""
    /// Converts the mic tap's native format into the PCM16 mono @ 24kHz that
    /// the Realtime API expects. Built lazily per session because the input
    /// node's hardware format isn't known until the engine is configured.
    private var pcm16Converter: AVAudioConverter?
    private var pcm16Format: AVAudioFormat?

    /// Synchronous re-entry guard for the async start window. `isRecording`
    /// alone is insufficient: `start()` only flips it to true at the very end,
    /// AFTER awaiting permission, so two near-simultaneous `start()` calls can
    /// both pass an `isRecording` check while it's still false and both reach
    /// `installTap`, which trips an AVAudioEngine assertion (issue #150 crash:
    /// "required condition is false: nullptr == Tap()"). This flag is set
    /// synchronously at the top of `start()` before any `await`, so the second
    /// caller bails immediately.
    private var isStarting = false

    init() {}

    // MARK: Public API

    /// Toggle recording. Idempotent — calling while idle starts; calling
    /// while recording stops and finalizes the transcript.
    func toggle() async {
        if isRecording {
            stop()
        } else {
            await start()
        }
    }

    /// Synchronous tear-down. Used by `ChatView.send()` to flush a final
    /// transcript before the message ships, and by `toggle()` itself.
    func stop() {
        // Belt-and-suspenders: clear the start-in-progress flag too, so a
        // stop that races a start can never leave `isStarting` stuck true
        // (issue #150). `start()`'s own `defer` normally handles this.
        isStarting = false
        guard isRecording else { return }
        Self.log.info("stop() called (engine: \(self.engine == .openAI ? "openAI" : "onDevice", privacy: .public))")
        isRecording = false
        audioLevel = 0
        levelWindow.removeAll()
        levelTrace.reset()
        // No more VAD markers will arrive, so freeze the live signals rather
        // than leave a stale countdown running in the overlay (issue #429).
        // `provisionalText` is deliberately NOT cleared here: the socket drain
        // still delivers this utterance's deltas after stop(), and the overlay
        // should keep showing them until the normalized final supersedes them.
        isSpeechDetected = false
        silenceStartedAt = nil

        // Tear down the mic tap + engine first (shared by both engines).
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        switch engine {
        case .openAI:
            // Commit the buffered audio so OpenAI force-finalizes the current
            // segment. `finish()` KEEPS the socket open until the resulting
            // `…transcription.completed` arrives (or a short timeout), so the
            // final transcript is delivered through `onCompleted` and never
            // discarded (issue #151). The mic tap is already removed above, so
            // no more audio is appended; the transcript will land async and
            // bump `didFinalizeTranscript` for the caller to finalize off.
            pcm16Converter = nil
            pcm16Format = nil
            // `openAI` is an actor; hop off the main actor to commit + drain.
            let socket = openAI
            Task { await socket.finish() }
        case .onDevice:
            // Cancel the synthesized silence-segmentation timer so no pending
            // finalize fires after teardown (issue #156). Any in-progress partial
            // is intentionally discarded here — a mid-word utterance interrupted
            // by Done shouldn't fire a stray `onUtteranceFinalized`.
            onDeviceSilenceTimer?.cancel()
            onDeviceSilenceTimer = nil
            // End-of-audio first, then tear down. `endAudio()` lets SFSpeech
            // finalize a "best result" partial; cancelling would discard it.
            request?.endAudio()
            request = nil
            task = nil
        }

        // Deactivate the audio session so Music / podcasts resume cleanly.
        // `.notifyOthersOnDeactivation` is what makes the resume happen.
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Non-fatal — the next `start()` will reset the category anyway.
        }
    }

    // MARK: Private

    private func start() async {
        // Re-entry guard: bail if we're already recording OR mid-start. This
        // runs synchronously before any `await`, so a second concurrent
        // `start()` can't slip through the async permission window and install
        // a duplicate tap (issue #150). Cleared on every exit via `defer`.
        guard !isRecording && !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        errorMessage = nil
        transcript = ""
        committedTranscript = ""
        loggedFirstChunk = false
        loggedFirstDelta = false
        // Fresh capture signals (issue #429). `isConnected` is set below once
        // the engine is chosen: the on-device path has no socket to wait on.
        provisionalText = ""
        isSpeechDetected = false
        silenceStartedAt = nil
        isConnected = false
        levelTrace.reset()

        // Pick the engine for this session: OpenAI when a key is present,
        // on-device SFSpeech otherwise (keyless / offline fallback).
        let keyPresent = (AppConfig.openAIAPIKey?.isEmpty == false)
        let useOpenAI = keyPresent
        engine = useOpenAI ? .openAI : .onDevice
        // The on-device recognizer has no socket, so there is nothing to wait
        // for: report connected immediately or the overlay would sit in its
        // "Connecting" state forever on the keyless path (issue #429).
        isConnected = !useOpenAI
        Self.log.info("engine chosen: \(useOpenAI ? "openAI" : "onDevice", privacy: .public) (openAI key present: \(keyPresent, privacy: .public))")
        // idevicesyslog-visible (os.Logger .info lines aren't relayed). Never
        // logs the key itself — only whether one is present.
        NSLog("[voice] engine=%@ keyPresent=%@", useOpenAI ? "openAI" : "onDevice", keyPresent ? "true" : "false")

        // Microphone permission is required for both engines.
        let micOK = await Self.requestMicrophonePermission()
        guard micOK else {
            errorMessage = "Enable Microphone access for Dexter in Settings."
            return
        }

        if useOpenAI {
            await startOpenAI()
        } else {
            await startOnDevice()
        }
    }

    // MARK: OpenAI Realtime engine

    private func startOpenAI() async {
        guard let apiKey = AppConfig.openAIAPIKey, !apiKey.isEmpty else {
            // Shouldn't happen (start() already checked) — fall back defensively.
            await startOnDevice()
            return
        }

        // Audio session: `.record` + `.measurement` minimizes processing
        // (no echo cancellation tuned for voice calls); `.duckOthers` dims
        // background audio while we're listening.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Couldn't start the microphone (\(error.localizedDescription))."
            return
        }

        // Target format for the Realtime API: PCM16, mono, 24kHz.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ) else {
            errorMessage = "Couldn't configure audio for transcription."
            return
        }
        pcm16Format = targetFormat

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        pcm16Converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        // Open the socket and configure the transcription session. If the
        // connection setup throws, surface an error and bail before touching
        // the audio engine so we leave nothing half-initialized.
        do {
            try await openAI.connect(
                apiKey: apiKey,
                onDelta: { [weak self] delta in
                    // Deltas are incremental — append to build the running
                    // transcript. Hop to the main actor (socket callbacks are
                    // off the main actor). We intentionally do NOT guard on
                    // `isRecording` here: with server VAD the deltas (and the
                    // `…completed` below) arrive AFTER the user pauses / after a
                    // manual commit, by which point `stop()` may already have
                    // flipped `isRecording` false. Dropping them on that guard
                    // is exactly the discarded-transcript bug (issue #151). The
                    // engine guard alone is enough to ignore a stale session.
                    Task { @MainActor in
                        guard let self, self.engine == .openAI else { return }
                        // Deltas ARE surfaced as of issue #429, but only into
                        // `provisionalText`, never `transcript`.
                        //
                        // History: #151 discarded them outright, because before
                        // normalization a delta can be in Urdu (Perso-Arabic)
                        // script and the swap to Devanagari on `…completed`
                        // read as a glitch. The fix isn't to hide the text, it's
                        // to mark it unsettled: the overlay renders this muted
                        // and crossfades to ink on the final, so the correction
                        // looks like the text resolving.
                        //
                        // Unchanged from #151: this still isn't mid-speech
                        // feedback. With server VAD the whole delta stream
                        // arrives AFTER the pause, so this buys a progressive
                        // reveal over roughly half a second, not live dictation.
                        self.provisionalText += delta
                        if !self.loggedFirstDelta {
                            self.loggedFirstDelta = true
                            Self.log.info("delta received (surfaced as provisional)")
                        }
                    }
                },
                onCompleted: { [weak self] fullText in
                    // Authoritative final text for the utterance. Replace the
                    // running transcript with it so any delta drift is
                    // corrected. Only adopt non-empty finals. Survives past
                    // `stop()` for the same reason as `onDelta` above, and bumps
                    // `didFinalizeTranscript` so the caller can finalize off the
                    // transcript actually being present rather than a synchronous
                    // snapshot that races the network.
                    Task { @MainActor in
                        guard let self, self.engine == .openAI else { return }
                        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        // Normalize Urdu (Perso-Arabic) → Hindi (Devanagari) so
                        // the preview only ever shows Hindi or English, never
                        // Urdu. English / already-Devanagari text returns
                        // unchanged with no API call (issue #151).
                        let normalized = await HindiScriptNormalizer.normalize(trimmed)
                        // The session may have ended (or switched engine) during
                        // the async normalize — bail so we don't write stale text.
                        guard self.engine == .openAI else { return }
                        // Fold this utterance into the committed transcript and
                        // clear the pending deltas so the next utterance starts
                        // clean. Cumulative: multi-utterance dictation in one
                        // recording never drops earlier text.
                        self.committedTranscript = self.committedTranscript.isEmpty
                            ? normalized
                            : self.committedTranscript + " " + normalized
                        self.transcript = self.committedTranscript
                        // This utterance has settled: the provisional buffer has
                        // been superseded by the normalized text above (#429).
                        self.provisionalText = ""
                        self.didFinalizeTranscript &+= 1
                        // Surface THIS utterance as a discrete event (issue #156).
                        // The continuous voice overlay consumes these one at a
                        // time; the inline chat bar leaves the hook nil and reads
                        // only the accumulated `transcript` above. Fired after
                        // normalization so the payload is never raw Urdu.
                        self.onUtteranceFinalized?(normalized)
                        Self.log.info("transcript updated from completed (len=\(self.transcript.count, privacy: .public)); didFinalizeTranscript bumped to \(self.didFinalizeTranscript, privacy: .public)")
                        // idevicesyslog-visible. Length only, never the text.
                        NSLog("[voice] transcript set len=%d", self.transcript.count)
                        NSLog("[voice] finalize len=%d", self.transcript.count)
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.engine == .openAI else { return }
                        // Surface the message inline / to the overlay.
                        self.errorMessage = message
                        // A connection failure (never connected, transport
                        // error, or watchdog timeout) means there will be no
                        // transcript ever — the socket is already torn down on
                        // the transcriber side. If we're still flagged
                        // "recording", stop so `isRecording` flips false: that
                        // is the single signal both callers watch to leave the
                        // listening state cleanly instead of hanging (issue
                        // #151). A transient/server error mid-session is NOT a
                        // connection failure — leave the session alone there so
                        // the silence timer / stop() still drive finalize.
                        if message == OpenAIRealtimeTranscriber.connectionFailedMessage, self.isRecording {
                            Self.log.info("connection failure onError → stopping to flip isRecording")
                            NSLog("[voice] error: connection failed; stopping session")
                            self.stop()
                        }
                    }
                },
                onConnected: { [weak self] in
                    // The socket is genuinely up (issue #429). Until this lands
                    // the overlay shows "Connecting" rather than claiming to
                    // listen, which on a weak link was a real second of lying.
                    Task { @MainActor in
                        guard let self, self.engine == .openAI else { return }
                        self.isConnected = true
                        Self.log.info("socket connected → isConnected true")
                    }
                },
                onSpeechActivity: { [weak self] active in
                    // Server VAD turn markers. The only in-speech signal there
                    // is, and voice-gated by the server, so unlike raw amplitude
                    // it can't be tripped by a door slam (issue #429).
                    Task { @MainActor in
                        guard let self, self.engine == .openAI else { return }
                        self.isSpeechDetected = active
                        // Start the countdown from speech_stopped. Clearing it on
                        // speech_started is what makes a resumed sentence refill
                        // the arc instead of finalizing under the user.
                        self.silenceStartedAt = active ? nil : Date()
                    }
                }
            )
        } catch {
            errorMessage = "Couldn't reach voice transcription (\(error.localizedDescription))."
            return
        }

        // Install the mic tap: meter the level AND ship converted PCM16 to OpenAI.
        // Defensive removeTap before installTap (issue #150 crash guard).
        // The converter, target format, and OpenAI actor are captured as locals
        // (all `Sendable`/immutable refs) so the tap never reaches back into
        // `@MainActor` state from its background queue.
        let converter = pcm16Converter
        let outFormat = targetFormat
        let socket = openAI
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            // (1) Level metering — identical to the original path.
            let level = Self.normalizedRMS(buffer)
            Task { @MainActor in self?.publishLevel(level) }
            // (2) Convert + send to OpenAI. Done on this background queue (cheap).
            guard let converter, let data = Self.convertToPCM16(buffer, using: converter, to: outFormat) else { return }
            // Log the first converted chunk size once (not every buffer — this
            // tap fires continuously). The flag lives on the main actor.
            let chunkBytes = data.count
            Task { @MainActor in
                guard let self, !self.loggedFirstChunk else { return }
                self.loggedFirstChunk = true
                Self.log.info("first converted PCM16 chunk: \(chunkBytes, privacy: .public) bytes")
            }
            Task { await socket.appendAudio(data) }
        }
        Self.log.info("audio tap installed (OpenAI engine)")

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            let socket = openAI
            Task { await socket.finish() }
            pcm16Converter = nil
            pcm16Format = nil
            errorMessage = "Couldn't start audio capture (\(error.localizedDescription))."
            return
        }

        isRecording = true
    }

    /// Convert one mic buffer to PCM16 mono @ 24kHz and return the raw little-
    /// endian bytes. Pure function — safe to call on the audio tap's background
    /// queue. Returns nil if conversion yields nothing.
    private nonisolated static func convertToPCM16(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outFormat: AVAudioFormat
    ) -> Data? {
        // Output capacity scaled by the sample-rate ratio (input → 24kHz).
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }

        var fed = false
        var convErr: NSError?
        let status = converter.convert(to: outBuffer, error: &convErr) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, convErr == nil, outBuffer.frameLength > 0,
              let channelData = outBuffer.int16ChannelData else { return nil }

        let byteCount = Int(outBuffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }

    // MARK: On-device (SFSpeech) fallback engine

    private func startOnDevice() async {
        engine = .onDevice

        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available on this device."
            return
        }

        // Speech-recognition permission (mic already granted by start()).
        let speechOK = await Self.requestSpeechAuthorization()
        guard speechOK else {
            errorMessage = "Enable Speech Recognition for Dexter in Settings."
            return
        }

        // Audio session: `.record` + `.measurement` minimizes processing
        // (no echo cancellation tuned for voice calls); `.duckOthers` dims
        // background audio while we're listening.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Couldn't start the microphone (\(error.localizedDescription))."
            return
        }

        // Build the recognition request. On-device only — if the model
        // isn't installed for the locale, `start()` will fail and we
        // surface the error rather than silently falling back to the
        // server pipeline.
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        request.taskHint = .dictation
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // Defensive: remove any stale tap before installing a fresh one. A
        // node can hold at most one tap per bus; installing over an existing
        // tap trips "required condition is false: nullptr == Tap()" and
        // crashes (issue #150). `removeTap` on a bus with no tap is a no-op.
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // The tap fires on a background queue, but the request's
            // append is thread-safe per Apple's docs.
            self?.request?.append(buffer)
            // Compute a normalized, smoothed amplitude for the waveform. Done on
            // this background queue (cheap RMS over the buffer), then the
            // smoothed scalar is hopped to the main actor for publishing.
            guard let self else { return }
            let level = Self.normalizedRMS(buffer)
            Task { @MainActor in self.publishLevel(level) }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.request = nil
            errorMessage = "Couldn't start audio capture (\(error.localizedDescription))."
            return
        }

        isRecording = true

        startOnDeviceTask(with: request)
    }

    /// Attach a `recognitionTask` to `request` and wire the partial-result
    /// callback. Factored out of `startOnDevice()` so it can be called again to
    /// rotate the recognition after each finalized utterance (issue #156) WITHOUT
    /// touching the audio engine or the mic tap.
    private func startOnDeviceTask(with request: SFSpeechAudioBufferRecognitionRequest) {
        guard let recognizer else { return }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            // `recognitionTask` callback isn't main-actor isolated, so hop.
            Task { @MainActor in
                // Ignore callbacks from a task we've already rotated away from
                // (a late partial from the previous utterance's task): only the
                // request currently wired to the tap is authoritative.
                guard self.request === request else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    // Synthesized VAD (issue #156): each non-empty partial arms /
                    // re-arms a silence timer. When the text stops changing for
                    // `onDeviceSilenceDebounce`, we treat the pause as an utterance
                    // boundary, fire `onUtteranceFinalized`, and rotate to a fresh
                    // request+task so the next utterance starts clean. `isFinal`
                    // only ever lands when `stop()` calls `endAudio()`, so we do
                    // NOT depend on it for per-utterance segmentation.
                    let trimmed = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self.armOnDeviceSilenceTimer()
                    }
                }
                if let error {
                    // SFSpeech surfaces a "no speech detected" code as an
                    // error too — treat any error as terminal so the user
                    // can re-tap to try again. Error code 1110 is the
                    // common "no speech detected" — silence it so the bar
                    // doesn't feel broken when the user taps mic without
                    // speaking.
                    let nsErr = error as NSError
                    if nsErr.code != 1110 {
                        self.errorMessage = error.localizedDescription
                    }
                    if self.isRecording {
                        self.stop()
                    }
                }
            }
        }
    }

    /// (Re)arm the on-device silence timer. Cancels any pending timer and starts a
    /// fresh `onDeviceSilenceDebounce`-long sleep; if no new partial re-arms it in
    /// that window, `finalizeOnDeviceUtterance()` fires. Task-based to match the
    /// file's structured-concurrency style; cancellation makes the re-arm cheap.
    private func armOnDeviceSilenceTimer() {
        onDeviceSilenceTimer?.cancel()
        let delay = onDeviceSilenceDebounce
        onDeviceSilenceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.finalizeOnDeviceUtterance()
        }
    }

    /// Finalize the current on-device utterance: fire `onUtteranceFinalized` with
    /// the accumulated text (if non-empty) and rotate the recognition so the NEXT
    /// utterance is recognized fresh rather than accumulated on top (issue #156).
    ///
    /// The rotation ends the current `request`/`task` and starts a new pair, but
    /// KEEPS `audioEngine` + the input tap running. The tap appends to whatever
    /// `self.request` currently is, so re-pointing it is all that's needed to
    /// route audio into the new segment — we never stop/restart the engine or
    /// reinstall the tap (which risks the `nullptr == Tap()` crash, issue #150).
    private func finalizeOnDeviceUtterance() {
        onDeviceSilenceTimer = nil
        guard isRecording, engine == .onDevice else { return }

        let finalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        // End the current recognition segment.
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil

        // Empty/whitespace-only utterance: don't fire, but still rotate so a long
        // silence doesn't wedge us on a stale request.
        if !finalized.isEmpty {
            didFinalizeTranscript &+= 1
            // Mirror the OpenAI `onCompleted` contract: fire the discrete event on
            // the main actor with the finalized text (issue #156).
            onUtteranceFinalized?(finalized)
            Self.log.info("on-device utterance finalized (len=\(finalized.count, privacy: .public)); didFinalizeTranscript bumped to \(self.didFinalizeTranscript, privacy: .public)")
            NSLog("[voice] on-device finalize len=%d", finalized.count)
        }

        // Reset the running transcript and spin up a fresh request+task. The tap
        // is untouched and will start appending buffers to the new request as soon
        // as it's assigned below.
        transcript = ""
        let fresh = SFSpeechAudioBufferRecognitionRequest()
        fresh.shouldReportPartialResults = true
        fresh.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) {
            fresh.addsPunctuation = true
        }
        fresh.taskHint = .dictation
        self.request = fresh
        startOnDeviceTask(with: fresh)
    }

    // MARK: Audio level metering

    /// RMS of the buffer's first channel, mapped from `meterFloorDB` to 0–1.
    /// Pure function, safe to call on the audio tap's background queue.
    ///
    /// The floor was -40 dBFS and that made this meter effectively dead (issue
    /// #429). The session runs in `.measurement` mode, which deliberately
    /// disables Apple's input processing and automatic gain control, so the tap
    /// sees RAW microphone audio. Unprocessed conversational speech has an RMS
    /// around -45 to -35 dBFS, so a -40 floor clamped most of a sentence to
    /// exactly zero. Only a hard consonant at the start of a phrase punched
    /// above it, which is why the waveform twitched at the top of a sentence and
    /// then flatlined for the rest of it.
    ///
    /// -60 dBFS covers quiet and distant speech. The wider range does let room
    /// tone register, which is what the adaptive gain in `VoiceLevelTrace`
    /// exists to absorb.
    private nonisolated static func normalizedRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        let samples = channelData[0]
        var sumSquares: Float = 0
        for i in 0..<frameCount {
            let s = samples[i]
            sumSquares += s * s
        }
        let rms = sqrt(sumSquares / Float(frameCount))
        // Convert to dBFS, clamp to the floor, then linear-map to 0–1.
        let db = 20 * log10(max(rms, 1e-7))
        let floorDB = meterFloorDB
        let clamped = max(floorDB, min(0, db))
        return (clamped - floorDB) / -floorDB
    }

    /// Quietest level the meter resolves. See `normalizedRMS`.
    nonisolated static let meterFloorDB: Float = -60

    #if DEBUG
    /// Push a synthetic amplitude through the same path a real buffer takes.
    /// Visual-QA only (#429): the iOS Simulator cannot start the on-device
    /// recognizer and has no usable mic, so the listening state is otherwise
    /// impossible to see without a physical device. Several rounds of size and
    /// colour tuning were done blind for exactly this reason.
    func debugInjectLevel(_ level: Float) {
        publishLevel(level)
    }
    #endif

    /// Append a new reading to the rolling window and publish the average.
    private func publishLevel(_ level: Float) {
        levelWindow.append(level)
        if levelWindow.count > levelWindowSize {
            levelWindow.removeFirst(levelWindow.count - levelWindowSize)
        }
        let avg = levelWindow.reduce(0, +) / Float(levelWindowSize == 0 ? 1 : levelWindow.count)
        audioLevel = avg
        // Record into the history the waveform and aurora read (issue #429).
        //
        // This MUST happen here, at the metering cadence (~47 buffers/sec), and
        // not in a SwiftUI `onChange`. The first cut recorded from the view and
        // the bars never left their rest position: `onChange` only samples when
        // the body happens to re-evaluate, so the history was starved and every
        // delayed tap read silence. The audio path is the only clock that
        // actually knows when a new amplitude exists.
        levelTrace.record(avg)
    }

    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private static func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}

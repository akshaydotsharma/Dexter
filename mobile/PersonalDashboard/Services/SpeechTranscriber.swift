import AVFoundation
import Foundation
import Observation
import Speech

/// On-device speech-to-text for the chat input bar (issue #83).
///
/// Wraps `SFSpeechRecognizer` + `AVAudioEngine`. All recognition happens on
/// the phone — `requiresOnDeviceRecognition = true`. Audio never leaves the
/// device; nothing is uploaded to Apple's servers and nothing is uploaded
/// to Anthropic until the user hits send.
///
/// Usage from a SwiftUI view:
///
///   @State private var transcriber = SpeechTranscriber()
///   ...
///   ChatInputBar(... onMic: { Task { await transcriber.toggle() } })
///   .onChange(of: transcriber.transcript) { _, new in
///       if transcriber.isRecording { viewModel.draftInput = new }
///   }
@Observable
@MainActor
final class SpeechTranscriber {

    /// Live partial transcript while recording. Replaced (not appended)
    /// every time `SFSpeechRecognizer` emits a partial result, because the
    /// system already returns the full running transcript per callback.
    private(set) var transcript: String = ""

    /// True between a successful start and the corresponding stop. The
    /// chat view uses this both to mirror `transcript` into the input
    /// field and to swap the mic icon for a recording indicator.
    private(set) var isRecording: Bool = false

    /// Surfaced inline above the input bar when permission is denied or
    /// the audio engine fails. Cleared on the next successful `toggle()`.
    var errorMessage: String?

    // MARK: Private state

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
        guard isRecording else { return }
        isRecording = false

        // End-of-audio first, then tear down the engine. `endAudio()` lets
        // SFSpeech finalize a "best result" partial; cancelling the task
        // would discard it.
        request?.endAudio()
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request = nil
        task = nil

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
        errorMessage = nil
        transcript = ""

        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available on this device."
            return
        }

        // Permissions: speech recognition + microphone. Both must be granted
        // before we touch the audio engine, otherwise `installTap` traps.
        let speechOK = await Self.requestSpeechAuthorization()
        guard speechOK else {
            errorMessage = "Enable Speech Recognition for Dexter in Settings."
            return
        }
        let micOK = await Self.requestMicrophonePermission()
        guard micOK else {
            errorMessage = "Enable Microphone access for Dexter in Settings."
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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // The tap fires on a background queue, but the request's
            // append is thread-safe per Apple's docs.
            self?.request?.append(buffer)
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

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            // `recognitionTask` callback isn't main-actor isolated, so hop.
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        // Final result lands when `endAudio()` is called
                        // from `stop()`. Nothing to do here — `stop()`
                        // already set `isRecording = false`.
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

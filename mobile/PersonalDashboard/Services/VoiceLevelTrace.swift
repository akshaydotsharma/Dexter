import Foundation

/// Short rolling history of microphone amplitude, plus the pure maths the voice
/// overlay's waveform and aurora both derive their motion from (issue #429).
///
/// Why a history and not just the current level: if every bar reads the same
/// instantaneous amplitude they all move as one, which reads as a single
/// throbbing block rather than a waveform. Giving each bar a slightly older
/// sample makes energy ripple outward from the centre, and feeding the aurora
/// blobs from other taps on the SAME buffer is what makes the background surge
/// on the same rhythm as the bars instead of drifting independently.
///
/// Deliberately a plain struct with no SwiftUI or AVFoundation in sight, so the
/// mapping can be tested directly. `VoiceCaptureOverlay` owns one, records into
/// it on every `audioLevel` change, and hands it to both views.
struct VoiceLevelTrace: Equatable {

    /// Samples retained. At the tap's ~47 buffers/sec this is a little over a
    /// second of history, which is far more than the deepest tap needs (the
    /// outermost aurora blob reads 20 frames back, about 0.4s).
    static let capacity = 64

    /// Ring buffer. Starts silent so the first frames after a start render as
    /// rest rather than as a spike.
    private var samples: [Float]

    /// Index the NEXT sample will be written to.
    private var writeIndex: Int = 0

    /// Decaying running peak, the basis of the adaptive gain.
    private var peak: Float = Self.minimumPeak

    /// Per-frame decay applied to `peak`. At the tap's ~47 Hz this halves the
    /// reference roughly every second.
    ///
    /// Tuned by `testPeakDecaysSoQuietSpeechRecoversAfterALoudBurst`: at 0.993
    /// (a two-second half-life) one loud burst left the following quiet speech
    /// reading under half scale four seconds later, so a single raised voice
    /// flattened the waveform for the rest of the sentence. A syllable gap is
    /// only ~5 frames, which this barely moves, so faster recovery costs no
    /// visible pumping inside a word.
    static let peakDecay: Float = 0.985

    /// Floor on the gain reference. Without it a silent room would be amplified
    /// until room tone filled the bars.
    static let minimumPeak: Float = 0.08

    init() {
        samples = Array(repeating: 0, count: Self.capacity)
    }

    /// Most recent sample.
    var current: Float { level(delayedBy: 0) }

    /// Append one amplitude reading, clamped to the 0...1 the rest of the
    /// pipeline assumes. Out-of-range input is a caller bug, but clamping here
    /// keeps a bad frame from producing a bar taller than its track.
    mutating func record(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        samples[writeIndex] = clamped
        writeIndex = (writeIndex + 1) % Self.capacity
        // Adaptive gain reference: rises instantly to a new peak, decays slowly.
        peak = max(peak * Self.peakDecay, max(clamped, Self.minimumPeak))
    }

    /// Current gain multiplier. The visualisation is scaled by this so it spans
    /// its full range whatever the input level actually is.
    var gain: Float { 1 / max(peak, Self.minimumPeak) }

    /// Amplitude `frames` ago, scaled by the adaptive gain and clamped to 0...1.
    ///
    /// This is what the visualisation should read, and it is the part that was
    /// missing (issue #429). Mapping raw dBFS straight to bar height assumes the
    /// microphone delivers a predictable level, which it does not: `.measurement`
    /// mode disables AGC, so the raw signal depends on the room, the distance to
    /// the phone, and how loudly the user happens to be speaking. Normalising
    /// against a decaying peak is what makes a waveform look alive for everyone
    /// rather than only for people who shout, and it is what the voice UIs this
    /// is modelled on actually do.
    func normalizedLevel(delayedBy frames: Int) -> Float {
        min(1, level(delayedBy: frames) * gain)
    }

    /// Gain-scaled most recent sample.
    var normalizedCurrent: Float { normalizedLevel(delayedBy: 0) }

    /// The sample `frames` readings ago. 0 is the most recent. Reads deeper than
    /// `capacity` saturate at the oldest retained sample rather than wrapping
    /// around into fresh data, which would alias into a false echo.
    func level(delayedBy frames: Int) -> Float {
        let clamped = min(max(frames, 0), Self.capacity - 1)
        let index = (writeIndex - 1 - clamped + Self.capacity * 2) % Self.capacity
        return samples[index]
    }

    /// Clear the history. Called when a capture session starts so the previous
    /// session's tail can't ripple through the first frame of the new one.
    mutating func reset() {
        samples = Array(repeating: 0, count: Self.capacity)
        writeIndex = 0
        peak = Self.minimumPeak
    }

    // MARK: - Waveform mapping

    /// Bars in the overlay's waveform. Odd so there is a true centre bar for
    /// energy to ripple outward from.
    static let barCount = 7

    /// How many frames of delay bar `index` reads at. The centre bar is live;
    /// each step outward lags by `framesPerStep`, so a syllable lands in the
    /// middle and travels out to the edges.
    static func delayFrames(forBar index: Int, barCount: Int = barCount) -> Int {
        let centre = Double(barCount - 1) / 2
        let distance = abs(Double(index) - centre)
        return Int((distance * 3).rounded())
    }

    /// Height of bar `index` as a fraction of the track, 0...1.
    ///
    /// Two regimes, and the split is the point. Above the speech floor the bar
    /// is a meter: it reports the delayed amplitude, tapered slightly toward the
    /// edges so the row reads as a shape rather than a picket fence. Below it,
    /// the bars hold a flat line with a slow travelling shimmer, so silence
    /// looks attentive rather than either dead or fake-reactive.
    ///
    /// - Parameters:
    ///   - time: absolute time, only consulted at rest to phase the shimmer.
    static func heightFraction(
        forBar index: Int,
        trace: VoiceLevelTrace,
        time: Double,
        barCount: Int = barCount
    ) -> Double {
        let restFraction = 0.075
        guard trace.current >= speechFloor else {
            let shimmer = sin(time * 1.5 - Double(index) * 0.55)
            return restFraction * (1 + 0.22 * shimmer)
        }
        // Gain-scaled, not raw. See `normalizedLevel`.
        let delayed = Double(trace.normalizedLevel(delayedBy: delayFrames(forBar: index, barCount: barCount)))
        let centre = Double(barCount - 1) / 2
        let taper = 1 - abs(Double(index) - centre) / centre * 0.12
        // The 0.85 exponent lifts quiet speech off the floor; a linear map left
        // normal speaking volume looking almost flat.
        return restFraction + (1 - restFraction) * pow(delayed, 0.85) * taper
    }

    /// Raw amplitude below which the waveform is considered at rest.
    ///
    /// Deliberately compared against the RAW level, not the gain-scaled one:
    /// adaptive gain would happily amplify a silent room to full scale, and this
    /// is the gate that stops it. Retuned for the -60 dBFS meter floor, where
    /// room tone lands far lower than it did at -40.
    static let speechFloor: Float = 0.055

    // MARK: - Silence countdown

    /// How far through the server-VAD silence window we are, 0...1, where 1
    /// means the turn is about to finalize. Nil when speech is active or no
    /// silence has started, i.e. when there is nothing to count down.
    ///
    /// The small lead-in stops the indicator flickering on the natural gaps
    /// between words: a pause has to last past it before anything is drawn.
    static func silenceProgress(
        since start: Date?,
        now: Date,
        window: TimeInterval,
        leadIn: TimeInterval = 0.12
    ) -> Double? {
        guard let start, window > leadIn else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > leadIn else { return nil }
        return min(1, (elapsed - leadIn) / (window - leadIn))
    }
}

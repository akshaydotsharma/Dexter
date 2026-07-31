import XCTest
import SwiftUI
@testable import PersonalDashboard

/// The pure maths behind the voice overlay's waveform, aurora and silence
/// countdown (#429).
///
/// Worth testing rather than eyeballing because all three read from one shared
/// ring buffer, and the bugs it can produce are subtle in exactly the way a
/// screenshot won't catch: an off-by-one in the delay tap makes the bars move in
/// lockstep (which just looks like a slightly duller animation, not like a
/// defect), and a wrap-around read turns old samples into a phantom echo. The
/// countdown maths has a real deadline behind it, so a drift there means the UI
/// promises the user time the server is not giving them.
final class VoiceWaveformTests: XCTestCase {

    // MARK: - Ring buffer

    func testRecordsAndReadsBackMostRecentSample() {
        var trace = VoiceLevelTrace()
        trace.record(0.4)
        trace.record(0.9)
        XCTAssertEqual(trace.current, 0.9, accuracy: 0.0001)
        XCTAssertEqual(trace.level(delayedBy: 0), 0.9, accuracy: 0.0001)
        XCTAssertEqual(trace.level(delayedBy: 1), 0.4, accuracy: 0.0001)
    }

    func testStartsSilentSoFirstFrameRendersAtRest() {
        let trace = VoiceLevelTrace()
        XCTAssertEqual(trace.current, 0)
        XCTAssertEqual(trace.level(delayedBy: 12), 0)
    }

    func testClampsOutOfRangeInput() {
        var trace = VoiceLevelTrace()
        trace.record(4.2)
        XCTAssertEqual(trace.current, 1, accuracy: 0.0001, "a bad frame must not produce a bar taller than its track")
        trace.record(-0.5)
        XCTAssertEqual(trace.current, 0, accuracy: 0.0001)
    }

    /// The failure this guards: reading deeper than the buffer wraps into the
    /// newest samples, so a deep tap would replay current audio as if it were
    /// history. The aurora's outermost blob reads 20 frames back, and that echo
    /// would put it visibly out of phase with the bars.
    func testDeepReadSaturatesInsteadOfWrapping() {
        var trace = VoiceLevelTrace()
        for _ in 0..<VoiceLevelTrace.capacity { trace.record(0.1) }
        trace.record(0.95)
        XCTAssertEqual(trace.level(delayedBy: VoiceLevelTrace.capacity * 3), 0.1, accuracy: 0.0001)
        XCTAssertEqual(trace.level(delayedBy: -5), 0.95, accuracy: 0.0001, "negative delay should clamp to the newest sample")
    }

    func testWritePointerWrapsWithoutLosingOrder() {
        var trace = VoiceLevelTrace()
        // Overflow the buffer more than once, then check ordering still holds.
        for i in 0..<(VoiceLevelTrace.capacity * 2 + 7) {
            trace.record(Float(i % 10) / 10)
        }
        let newest = trace.level(delayedBy: 0)
        let previous = trace.level(delayedBy: 1)
        XCTAssertEqual(newest, Float((VoiceLevelTrace.capacity * 2 + 6) % 10) / 10, accuracy: 0.0001)
        XCTAssertEqual(previous, Float((VoiceLevelTrace.capacity * 2 + 5) % 10) / 10, accuracy: 0.0001)
    }

    func testResetClearsHistory() {
        var trace = VoiceLevelTrace()
        for _ in 0..<10 { trace.record(0.8) }
        trace.reset()
        XCTAssertEqual(trace.current, 0)
        XCTAssertEqual(trace.level(delayedBy: 5), 0)
    }

    // MARK: - Bar delay

    /// The centre bar must be live and each step outward must lag strictly more,
    /// otherwise energy doesn't travel and the row moves as one block.
    func testDelayIncreasesStrictlyOutwardFromCentre() {
        let count = VoiceLevelTrace.barCount
        let centre = count / 2
        XCTAssertEqual(VoiceLevelTrace.delayFrames(forBar: centre), 0, "centre bar reads live audio")

        for step in 1...(count / 2) {
            let inner = VoiceLevelTrace.delayFrames(forBar: centre - step + 1)
            let outer = VoiceLevelTrace.delayFrames(forBar: centre - step)
            XCTAssertGreaterThan(outer, inner, "bar \(centre - step) must lag bar \(centre - step + 1)")
        }
    }

    func testDelayIsSymmetricAboutTheCentre() {
        let count = VoiceLevelTrace.barCount
        for index in 0..<count {
            XCTAssertEqual(
                VoiceLevelTrace.delayFrames(forBar: index),
                VoiceLevelTrace.delayFrames(forBar: count - 1 - index),
                "an asymmetric ripple reads as a glitch, not a waveform"
            )
        }
    }

    func testDeepestBarTapStaysInsideTheBuffer() {
        let deepest = (0..<VoiceLevelTrace.barCount)
            .map { VoiceLevelTrace.delayFrames(forBar: $0) }
            .max() ?? 0
        XCTAssertLessThan(deepest, VoiceLevelTrace.capacity)
    }

    // MARK: - Height mapping

    func testSilenceHoldsBarsNearRest() {
        var trace = VoiceLevelTrace()
        for _ in 0..<20 { trace.record(0.01) }
        for index in 0..<VoiceLevelTrace.barCount {
            let height = VoiceLevelTrace.heightFraction(forBar: index, trace: trace, time: 12.0)
            XCTAssertGreaterThan(height, 0, "bars must never fully collapse")
            XCTAssertLessThan(height, 0.12, "at rest the row should read as a flat line")
        }
    }

    /// At rest the bars must still differ from each other at a given instant,
    /// or the "slow travelling shimmer" is really just a static line.
    func testRestShimmerVariesAcrossBars() {
        var trace = VoiceLevelTrace()
        trace.record(0.0)
        let heights = (0..<VoiceLevelTrace.barCount).map {
            VoiceLevelTrace.heightFraction(forBar: $0, trace: trace, time: 3.0)
        }
        XCTAssertGreaterThan(Set(heights.map { Int($0 * 10_000) }).count, 1)
    }

    func testLoudSpeechDrivesBarsWellAboveRest() {
        var trace = VoiceLevelTrace()
        for _ in 0..<40 { trace.record(0.95) }
        let centre = VoiceLevelTrace.heightFraction(
            forBar: VoiceLevelTrace.barCount / 2, trace: trace, time: 0
        )
        XCTAssertGreaterThan(centre, 0.8)
        XCTAssertLessThanOrEqual(centre, 1.0, "a bar must never exceed its track")
    }

    func testHeightNeverExceedsTrackAtMaximumAmplitude() {
        var trace = VoiceLevelTrace()
        for _ in 0..<VoiceLevelTrace.capacity { trace.record(1.0) }
        for index in 0..<VoiceLevelTrace.barCount {
            let height = VoiceLevelTrace.heightFraction(forBar: index, trace: trace, time: 7.5)
            XCTAssertLessThanOrEqual(height, 1.0, "bar \(index) overflowed its track")
        }
    }

    /// Quiet speech has to be visibly louder than silence, otherwise a soft
    /// talker gets the same flat line as an empty room.
    func testQuietSpeechReadsAboveTheRestFloor() {
        var trace = VoiceLevelTrace()
        for _ in 0..<40 { trace.record(0.18) }
        let centre = VoiceLevelTrace.heightFraction(
            forBar: VoiceLevelTrace.barCount / 2, trace: trace, time: 0
        )
        XCTAssertGreaterThan(centre, 0.18, "the 0.85 exponent should lift quiet speech clear of rest")
    }

    // MARK: - Adaptive gain
    //
    // The bug this exists to prevent: `.measurement` mode disables AGC, so raw
    // speech RMS can sit near the meter floor. Mapping raw amplitude straight to
    // bar height produced a waveform that only moved for loud, close talkers,
    // and looked completely dead the rest of the time.

    func testGainAmplifiesAConsistentlyQuietSignalToFullScale() {
        var trace = VoiceLevelTrace()
        for _ in 0..<80 { trace.record(0.14) }
        XCTAssertEqual(trace.normalizedCurrent, 1.0, accuracy: 0.05,
                       "a steady quiet voice should still fill the bars")
        XCTAssertGreaterThan(trace.gain, 1.0)
    }

    /// The gate that stops the gain turning an empty room into a light show.
    func testSilenceIsNotAmplified() {
        var trace = VoiceLevelTrace()
        for _ in 0..<80 { trace.record(0.004) }
        XCTAssertLessThan(trace.normalizedCurrent, 0.1)
        XCTAssertLessThan(trace.current, VoiceLevelTrace.speechFloor,
                          "room tone must stay under the rest gate")
        for index in 0..<VoiceLevelTrace.barCount {
            XCTAssertLessThan(
                VoiceLevelTrace.heightFraction(forBar: index, trace: trace, time: 4),
                0.12,
                "bar \(index) should be at rest in a silent room"
            )
        }
    }

    func testGainNeverExceedsFullScale() {
        var trace = VoiceLevelTrace()
        for _ in 0..<VoiceLevelTrace.capacity { trace.record(1.0) }
        XCTAssertLessThanOrEqual(trace.normalizedCurrent, 1.0)
        XCTAssertEqual(trace.gain, 1.0, accuracy: 0.0001, "a full-scale signal needs no gain")
    }

    /// A loud burst must not permanently flatten a following quiet passage; the
    /// reference has to decay back down. Deliberately measured over ~10s rather
    /// than ~4s: see `testGainPreservesDynamicsWithinASentence` for why the
    /// decay must stay slow.
    func testPeakDecaysSoQuietSpeechRecoversAfterALoudBurst() {
        var trace = VoiceLevelTrace()
        for _ in 0..<10 { trace.record(1.0) }
        let immediatelyAfter = trace.gain
        for _ in 0..<470 { trace.record(0.12) }  // ~10s at ~47 Hz
        XCTAssertGreaterThan(trace.gain, immediatelyAfter,
                             "the gain reference should decay back toward the quieter signal")
        XCTAssertGreaterThan(trace.normalizedCurrent, 0.5,
                             "quiet speech well after a shout should register again")
    }

    /// The regression that a screenshot caught and the suite did not.
    ///
    /// With a fast-decaying peak the gain reference chases the speech envelope
    /// rather than sitting above it, so `level / peak` is ~1 on every frame:
    /// every bar pegs at full height and the colour ramp pins at red. On device
    /// that rendered as a solid orange block instead of a waveform. The property
    /// that matters is not "loud speech reaches full scale", it is "a varying
    /// input produces a VARYING display".
    func testGainPreservesDynamicsWithinASentence() {
        var trace = VoiceLevelTrace()
        var heights: [Double] = []

        // Two seconds of syllable-modulated speech, the shape a real voice makes.
        for frame in 0..<94 {
            let t = Double(frame) / 47
            let syllable = abs(sin(t * .pi * 2.4))
            trace.record(Float(0.10 + 0.42 * syllable))
            heights.append(
                VoiceLevelTrace.heightFraction(
                    forBar: VoiceLevelTrace.barCount / 2, trace: trace, time: t
                )
            )
        }

        // Sample only the settled tail, so the initial gain ramp-up isn't what
        // creates the spread.
        let settled = Array(heights.suffix(60))
        let low = settled.min() ?? 0
        let high = settled.max() ?? 0
        XCTAssertGreaterThan(high - low, 0.35,
                             "syllables must produce visibly different bar heights, not a solid block")
        XCTAssertLessThan(low, 0.7, "quiet moments between syllables must drop well off full scale")
    }

    /// The colour consequence of the same defect: if height is pinned near full,
    /// the ramp is pinned at its hot end and every bar reads red.
    func testColourStaysOffThePeakForOrdinarySpeech() {
        var trace = VoiceLevelTrace()
        for frame in 0..<94 {
            let t = Double(frame) / 47
            trace.record(Float(0.10 + 0.42 * abs(sin(t * .pi * 2.4))))
        }
        let mid = VoiceLevelTrace.heightFraction(
            forBar: VoiceLevelTrace.barCount / 2, trace: trace, time: 2.0
        )
        // Mirrors VoiceWaveform.colorCurve.
        let rampPosition = pow(max(0, mid), 2.8)
        XCTAssertLessThan(rampPosition, 0.85,
                          "ordinary speech should not sit at the red end of the Ember ramp")
    }

    func testResetClearsTheGainReference() {
        var trace = VoiceLevelTrace()
        for _ in 0..<20 { trace.record(1.0) }
        trace.reset()
        XCTAssertEqual(trace.gain, 1 / VoiceLevelTrace.minimumPeak, accuracy: 0.0001)
    }

    /// The meter floor and the rest gate are tuned together. If someone widens
    /// one without the other, either speech clamps to zero again (the original
    /// defect) or room tone starts driving the bars.
    func testMeterFloorIsWideEnoughForUnprocessedSpeech() {
        XCTAssertLessThanOrEqual(
            SpeechTranscriber.meterFloorDB, -55,
            "measurement mode disables AGC; a floor above about -55 dBFS clamps normal speech to zero"
        )
    }

    /// The ripple itself: with a spike only in the newest frames, the centre bar
    /// should already be tall while the outermost is still reading the old quiet.
    func testEnergyReachesCentreBeforeEdges() {
        var trace = VoiceLevelTrace()
        for _ in 0..<VoiceLevelTrace.capacity { trace.record(0.02) }
        for _ in 0..<2 { trace.record(0.95) }

        let centre = VoiceLevelTrace.heightFraction(
            forBar: VoiceLevelTrace.barCount / 2, trace: trace, time: 0
        )
        let edge = VoiceLevelTrace.heightFraction(forBar: 0, trace: trace, time: 0)
        XCTAssertGreaterThan(centre, edge, "the centre must lead; if these are equal the delay line is not wired up")
    }

    // MARK: - Silence countdown

    func testNoCountdownBeforeSilenceStarts() {
        XCTAssertNil(VoiceLevelTrace.silenceProgress(since: nil, now: Date(), window: 0.7))
    }

    /// Natural gaps between words are shorter than the lead-in, and drawing a
    /// countdown for each would make the baseline strobe through a sentence.
    func testShortGapsDoNotStartTheCountdown() {
        let start = Date()
        XCTAssertNil(VoiceLevelTrace.silenceProgress(
            since: start, now: start.addingTimeInterval(0.05), window: 0.7
        ))
    }

    func testProgressRunsZeroToOneAcrossTheWindow() {
        let start = Date()
        let justAfterLeadIn = VoiceLevelTrace.silenceProgress(
            since: start, now: start.addingTimeInterval(0.13), window: 0.7
        )
        XCTAssertNotNil(justAfterLeadIn)
        XCTAssertEqual(justAfterLeadIn ?? -1, 0, accuracy: 0.05)

        let midway = VoiceLevelTrace.silenceProgress(
            since: start, now: start.addingTimeInterval(0.41), window: 0.7
        )
        XCTAssertEqual(midway ?? -1, 0.5, accuracy: 0.05)

        let atDeadline = VoiceLevelTrace.silenceProgress(
            since: start, now: start.addingTimeInterval(0.7), window: 0.7
        )
        XCTAssertEqual(atDeadline ?? -1, 1.0, accuracy: 0.02)
    }

    /// Past the deadline the finalize has already fired. Clamping matters
    /// because the arc is drawn as `1 - progress`: unclamped it would invert and
    /// start growing again.
    func testProgressClampsPastTheDeadline() {
        let start = Date()
        let overrun = VoiceLevelTrace.silenceProgress(
            since: start, now: start.addingTimeInterval(5), window: 0.7
        )
        XCTAssertEqual(overrun ?? -1, 1.0, accuracy: 0.0001)
    }

    /// The countdown is a promise about a real server deadline. If this drifts
    /// from the socket's configured VAD window, the UI is lying about how long
    /// the user has to keep thinking.
    func testVADWindowMatchesTheDocumentedSocketConfig() {
        XCTAssertEqual(
            SpeechTranscriber.vadSilenceWindow,
            0.7,
            accuracy: 0.0001,
            "must track OpenAIRealtimeTranscriber.vadSilenceMs (700)"
        )
    }

    // MARK: - Ember ramp

    func testEmberRampRunsInkToAmberToRed() {
        for dark in [true, false] {
            let ink = EmberRamp.components(fraction: 0, dark: dark)
            let amber = EmberRamp.components(fraction: 0.5, dark: dark)
            let red = EmberRamp.components(fraction: 1, dark: dark)

            // Amber is the warmest point: it should be the most yellow, i.e.
            // carry more green than either end.
            XCTAssertGreaterThan(amber.1, red.1, "amber should be yellower than the red peak (dark: \(dark))")
            XCTAssertGreaterThan(amber.0, ink.0, "amber should be redder than ink (dark: \(dark))")
        }
    }

    func testEmberRampClampsOutsideZeroToOne() {
        let below = EmberRamp.components(fraction: -3, dark: false)
        let atZero = EmberRamp.components(fraction: 0, dark: false)
        XCTAssertEqual(below.0, atZero.0, accuracy: 0.0001)

        let above = EmberRamp.components(fraction: 9, dark: false)
        let atOne = EmberRamp.components(fraction: 1, dark: false)
        XCTAssertEqual(above.2, atOne.2, accuracy: 0.0001)
    }

    /// Every stop must resolve to a legal colour in both schemes. A component
    /// outside 0...1 silently renders black on device rather than throwing.
    func testEmberComponentsStayInGamut() {
        for dark in [true, false] {
            for step in 0...20 {
                let (r, g, b) = EmberRamp.components(fraction: Double(step) / 20, dark: dark)
                for (name, value) in [("r", r), ("g", g), ("b", b)] {
                    XCTAssertTrue((0...1).contains(value), "\(name) out of gamut at step \(step), dark: \(dark)")
                }
            }
        }
    }

    /// Ember's stops are copies of token values, so they can drift silently when
    /// the palette moves. This is the tripwire.
    func testEmberStopsMatchDesignTokens() {
        XCTAssertEqual(EmberRamp.stops.count, 3)
        XCTAssertEqual(EmberRamp.stops[0].light, 0x1F1B16, "Tokens.ink light")
        XCTAssertEqual(EmberRamp.stops[0].dark, 0xF2EBDA, "Tokens.ink dark")
        XCTAssertEqual(EmberRamp.stops[1].light, 0xB45309, "Tokens.accentNotes light")
        XCTAssertEqual(EmberRamp.stops[1].dark, 0xF59E0B, "Tokens.accentNotes dark")
        XCTAssertEqual(EmberRamp.stops[2].light, 0xB91C1C, "Tokens.danger light")
        XCTAssertEqual(EmberRamp.stops[2].dark, 0xF87171, "Tokens.danger dark")
    }

    /// Light and dark must be genuinely different ramps. Reusing one set would
    /// put dark-mode ink (#F2EBDA, near-white) on a near-white light ground.
    func testEmberInkStopDiffersBetweenSchemes() {
        let light = EmberRamp.components(fraction: 0, dark: false)
        let dark = EmberRamp.components(fraction: 0, dark: true)
        XCTAssertNotEqual(light.0, dark.0, accuracy: 0.0001)
    }
}

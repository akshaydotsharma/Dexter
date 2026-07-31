import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The voice-capture overlay's hero indicator (issue #429): seven bars driven by
/// live microphone amplitude, replacing `InkOrb` on this surface.
///
/// Reads as a waveform rather than seven independent meters because each bar
/// samples a slightly older frame from the shared `VoiceLevelTrace` (see
/// `delayFrames(forBar:)`), so a syllable lands in the centre and travels
/// outward. Between phrases the bars hold a flat line with a slow travelling
/// shimmer: present, but not pretending to hear anything.
///
/// ### Colour (Ember)
///
/// Bar colour encodes loudness: ink when quiet, amber at speaking volume, red at
/// peaks. This overturns the strictly-monochrome note that `InkOrb` carried, and
/// does so deliberately, but under one rule: **hue is never the only carrier**.
/// Height and opacity still encode amplitude on their own, so the indicator
/// reads identically in greyscale and nothing is lost to colour vision
/// deficiency. Every stop is an existing accent token value.
///
/// ### Silence countdown
///
/// Server VAD finalizes a turn 700ms after speech stops, and that deadline used
/// to be completely invisible: a pause mid-sentence just ended the capture. The
/// baseline rule under the bars depletes toward the centre across that window
/// and warms as it goes, so the moment before it stops is legible. Speaking
/// again clears it, because `silenceStartedAt` resets on `speech_started`.
struct VoiceWaveform: View {

    enum Mode: Equatable {
        /// Socket still coming up. Bars present but flat and dim: the shape is
        /// already there, only the life is missing.
        case connecting
        /// Recording, amplitude-reactive.
        case listening
        /// The utterance is being processed. No amplitude; a slow autonomous
        /// pulse so the surface doesn't die while the AI call is in flight.
        case thinking
        /// Terminal / unavailable states. Static and dim.
        case dim
    }

    var mode: Mode
    var trace: VoiceLevelTrace
    /// 0...1 through the VAD silence window, or nil when nothing is pending.
    var silenceProgress: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Sized to fill the overlay's animation zone, which is 38% of the screen.
    // The first cut used a 116pt track and read as a row of dots stranded in a
    // 320pt space, even while reacting correctly.
    private let barWidth: CGFloat = 9
    private let barSpacing: CGFloat = 13
    private let trackHeight: CGFloat = 184

    var body: some View {
        if reduceMotion {
            reducedMotionBars
        } else {
            animatedBars
        }
    }

    // MARK: Reduce motion

    /// A static, honest snapshot: mid-height bars, no animation, no colour ramp.
    /// Mirrors what `InkOrb` did for this accessibility setting.
    private var reducedMotionBars: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<VoiceLevelTrace.barCount, id: \.self) { index in
                let centre = Double(VoiceLevelTrace.barCount - 1) / 2
                let taper = 1 - abs(Double(index) - centre) / centre * 0.45
                Capsule(style: .continuous)
                    .fill(Tokens.ink.opacity(0.5))
                    .frame(width: barWidth, height: trackHeight * 0.42 * taper)
            }
        }
        .frame(height: trackHeight)
        .accessibilityHidden(true)
    }

    // MARK: Animated

    private var animatedBars: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isStatic)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: barSpacing) {
                    ForEach(0..<VoiceLevelTrace.barCount, id: \.self) { index in
                        bar(index: index, time: time)
                    }
                }
                .frame(height: trackHeight)

                baseline
            }
            .animation(.easeOut(duration: 0.25), value: mode)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func bar(index: Int, time: Double) -> some View {
        let fraction = heightFraction(index: index, time: time)
        Capsule(style: .continuous)
            .fill(EmberRamp.color(fraction: colorFraction(fraction), opacity: opacity(for: fraction)))
            .frame(width: barWidth, height: max(barWidth, trackHeight * fraction))
            // Springs the bar to its new height rather than snapping. Fast
            // enough to keep up with syllables, damped enough not to jitter.
            .animation(.spring(response: 0.16, dampingFraction: 0.62), value: fraction)
    }

    /// The depleting rule under the bars. Full width while speech is live,
    /// shrinking toward the centre and warming as the VAD window runs out.
    @ViewBuilder
    private var baseline: some View {
        let progress = silenceProgress ?? 0
        let remaining = 1 - progress
        Capsule(style: .continuous)
            .fill(
                silenceProgress == nil
                    ? Tokens.border
                    : EmberRamp.color(fraction: 0.5 * progress, opacity: 0.75)
            )
            .frame(
                width: max(barWidth, totalWidth * (silenceProgress == nil ? 1 : remaining)),
                height: 2
            )
            .animation(.linear(duration: 0.1), value: progress)
            .opacity(mode == .listening ? 1 : 0.25)
    }

    private var totalWidth: CGFloat {
        let count = CGFloat(VoiceLevelTrace.barCount)
        return count * barWidth + (count - 1) * barSpacing
    }

    // MARK: Mapping

    /// Static modes don't need the 30fps timeline driving them.
    private var isStatic: Bool {
        switch mode {
        case .dim: return true
        case .connecting, .listening, .thinking: return false
        }
    }

    private func heightFraction(index: Int, time: Double) -> Double {
        switch mode {
        case .listening:
            return VoiceLevelTrace.heightFraction(forBar: index, trace: trace, time: time)
        case .connecting:
            // Flat and still: present, but making no claim to hear anything.
            return 0.06
        case .thinking:
            // Slow travelling wave with no amplitude behind it, so the surface
            // stays alive while the AI call is in flight without implying the
            // mic is still open.
            let wave = (sin(time * 2.2 - Double(index) * 0.7) + 1) / 2
            return 0.10 + 0.16 * wave
        case .dim:
            return 0.06
        }
    }

    /// Where this bar sits on the Ember ramp. Only `.listening` earns colour:
    /// in every other mode amplitude means nothing, so hue would be decorative.
    private func colorFraction(_ heightFraction: Double) -> Double {
        mode == .listening ? heightFraction : 0
    }

    private func opacity(for fraction: Double) -> Double {
        switch mode {
        case .listening:  return 0.34 + 0.56 * min(1, fraction / 0.9)
        case .connecting: return 0.20
        case .thinking:   return 0.30 + 0.25 * min(1, fraction / 0.3)
        case .dim:        return 0.15
        }
    }
}

// MARK: - Ember ramp

/// Ink → amber → red, interpolated in sRGB and resolved per colour scheme
/// (issue #429).
///
/// Built as a dynamic `UIColor` rather than a static one so the ramp keeps
/// working when the system theme flips mid-capture. Interpolating `Tokens`
/// values directly isn't possible: they're already dynamic colours, and
/// `Color.mix(with:by:)` is iOS 18 while this target is 17.0. So the stops are
/// held here as raw components, matching `Tokens.ink`, `Tokens.accentNotes` and
/// `Tokens.danger` in both schemes.
enum EmberRamp {

    /// (light, dark) hex pairs. Keep in step with Tokens; asserted by
    /// `VoiceWaveformTests.testEmberStopsMatchDesignTokens`.
    static let stops: [(light: UInt32, dark: UInt32)] = [
        (0x1F1B16, 0xF2EBDA),  // Tokens.ink
        (0xB45309, 0xF59E0B),  // Tokens.accentNotes
        (0xB91C1C, 0xF87171)   // Tokens.danger
    ]

    /// Colour at `fraction` (0...1) along the ramp at the given opacity.
    static func color(fraction: Double, opacity: Double) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { trait in
            let isDark = trait.userInterfaceStyle == .dark
            let (r, g, b) = components(fraction: fraction, dark: isDark)
            return UIColor(red: r, green: g, blue: b, alpha: CGFloat(min(max(opacity, 0), 1)))
        })
        #else
        let (r, g, b) = components(fraction: fraction, dark: false)
        return Color(red: r, green: g, blue: b).opacity(opacity)
        #endif
    }

    /// Linear sRGB interpolation across the stops. Exposed for tests.
    static func components(fraction: Double, dark: Bool) -> (CGFloat, CGFloat, CGFloat) {
        let clamped = min(max(fraction, 0), 1)
        let scaled = clamped * Double(stops.count - 1)
        let lower = min(stops.count - 2, Int(scaled))
        let t = scaled - Double(lower)
        let a = rgb(dark ? stops[lower].dark : stops[lower].light)
        let b = rgb(dark ? stops[lower + 1].dark : stops[lower + 1].light)
        return (
            a.0 + (b.0 - a.0) * CGFloat(t),
            a.1 + (b.1 - a.1) * CGFloat(t),
            a.2 + (b.2 - a.2) * CGFloat(t)
        )
    }

    private static func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255
        )
    }
}

import SwiftUI

/// The voice-capture overlay's hero animation (concept doc Section 2): a single
/// `Tokens.ink` filled circle that breathes with the mic amplitude, plus a
/// soft trailing outer ring that lags the inner circle. Strictly monochrome —
/// the depth of the ink is the signal, never hue.
///
/// Modes map to the overlay state machine:
///   - `.listening`: amplitude-reactive (scale 1.0→1.33, opacity 0.22→0.90),
///     with an autonomous 1.4s sine pulse layered in for the gaps between
///     words so it never reads as dead.
///   - `.settled`: compressed to 0.88 scale, animation stopped (State A1).
///   - `.thinking`: slow 2.0s autonomous pulse (0.30–0.55 opacity), no
///     amplitude (State C).
///   - `.rest`: faded to 0.15 opacity, still (State D).
///   - `.dim`: 0.15 opacity, still (States F/G — feature unavailable).
///   - `.idle`: 0.22 opacity, still (State E — nothing heard).
///
/// Reduce-motion collapses every mode to a static filled circle (0.50 opacity)
/// with a thin border ring for legibility.
struct InkOrb: View {
    enum Mode: Equatable {
        case listening
        case settled
        case thinking
        case rest
        case dim
        case idle
    }

    var mode: Mode
    /// Normalized mic amplitude (0–1). Only consulted in `.listening`.
    var level: Float = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let baseDiameter: CGFloat = 120

    var body: some View {
        if reduceMotion {
            reducedMotionOrb
        } else {
            animatedOrb
        }
    }

    // MARK: Reduce-motion

    private var reducedMotionOrb: some View {
        ZStack {
            Circle()
                .fill(Tokens.ink)
                .opacity(0.50)
            Circle()
                .strokeBorder(Tokens.border, lineWidth: 1)
                .frame(width: 144, height: 144)
        }
        .frame(width: baseDiameter, height: baseDiameter)
        .accessibilityHidden(true)
    }

    // MARK: Animated

    private var animatedOrb: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isStatic)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let (innerScale, innerOpacity, ringScale, ringOpacity) = values(at: t)

            ZStack {
                // Trailing outer ring — lags the inner circle (springs below).
                Circle()
                    .stroke(Tokens.ink, lineWidth: 1)
                    .frame(width: 140, height: 140)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)
                    .animation(.spring(response: 0.28, dampingFraction: 0.70).delay(0.08), value: level)

                // Inner filled circle — the hero.
                Circle()
                    .fill(Tokens.ink)
                    .frame(width: baseDiameter, height: baseDiameter)
                    .scaleEffect(innerScale)
                    .opacity(innerOpacity)
                    .animation(.spring(response: 0.18, dampingFraction: 0.65), value: level)
            }
            .animation(.easeOut(duration: modeTransitionDuration), value: mode)
        }
        .accessibilityHidden(true)
    }

    /// Static modes don't need the 30fps timeline driving them.
    private var isStatic: Bool {
        switch mode {
        case .settled, .rest, .dim, .idle: return true
        case .listening, .thinking: return false
        }
    }

    private var modeTransitionDuration: Double {
        switch mode {
        case .settled: return 0.15
        case .thinking: return 0.3
        case .rest: return 0.4
        default: return 0.2
        }
    }

    /// Returns (innerScale, innerOpacity, ringScale, ringOpacity) for time `t`.
    private func values(at t: Double) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        switch mode {
        case .listening:
            // Amplitude drives the headline motion; an autonomous 1.4s sine
            // fills the silence between words so the orb still breathes.
            let amp = CGFloat(max(0, min(1, level)))
            let idle = (sin(2 * .pi * t / 1.4) + 1) / 2  // 0...1
            let idleScale = 1.0 + 0.08 * idle
            let idleOpacity = 0.22 + 0.20 * idle
            // Blend: amplitude takes over as the user speaks.
            let innerScale = max(idleScale, 1.0 + 0.33 * amp)
            let innerOpacity = max(idleOpacity, 0.22 + 0.68 * amp)
            let ringScale = 1.0 + (200.0 / 140.0 - 1.0) * amp   // 140pt → 200pt
            let ringOpacity = 0.18 * amp
            return (innerScale, innerOpacity, ringScale, ringOpacity)

        case .settled:
            return (0.88, 0.80, 1.0, 0)

        case .thinking:
            // Slow 2.0s waiting pulse, no amplitude.
            let p = (sin(2 * .pi * t / 2.0) + 1) / 2
            let scale = 1.0 + 0.10 * p
            let opacity = 0.30 + 0.25 * p
            return (scale, opacity, 1.0, 0)

        case .rest:
            return (1.0, 0.15, 1.0, 0)

        case .dim:
            return (1.0, 0.15, 1.0, 0)

        case .idle:
            return (1.0, 0.22, 1.0, 0)
        }
    }
}

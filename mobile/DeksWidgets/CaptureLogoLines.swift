import SwiftUI

/// Animated three-line riff on the Deks app icon, tuned for Live Activity
/// surfaces (Dynamic Island, lock screen banner, expanded view).
///
/// Visual contract:
///   - Three rounded capsules, top-aligned to the leading edge.
///   - Base widths echo the icon: ~52% (with a bullet), ~100% middle,
///     ~78% bottom.
///   - During `.processing` they oscillate horizontally like a soft
///     waveform: each line uses a different phase offset so the whole
///     thing reads as "alive", not "marching in lockstep".
///   - On `.complete` / `.failed`, they freeze at their base widths so
///     the surface stops drawing attention right before dismissal.
///
/// Why it reads phase from state, not `TimelineView`:
///   `TimelineView(.animation)` does NOT drive continuous redraws inside
///   the *compact* Dynamic Island slot. iOS only redraws the compact pill
///   when the activity's `ContentState` mutates (`activity.update(...)`),
///   so the controller ticks `animationPhase` every ~500 ms while the
///   activity is in `.processing`. Each tick triggers a redraw and we
///   recompute the line widths from the new phase. Settled phases hold
///   their final value because no further updates fire.
struct CaptureLogoLines: View {

    enum Size {
        /// Compact leading region of the Dynamic Island. Tiny — needs a
        /// chunky stroke so the lines stay visible at a glance.
        case compactLeading
        /// Minimal (when another activity is on the trailing side) and
        /// the centre dot when the island shrinks back. Identical scale.
        case minimal
        /// Expanded leading slot. Roughly the size of a macOS menu-bar
        /// icon — big enough to feel like the icon, small enough to leave
        /// room for the status text on the trailing side.
        case expandedLeading
        /// Lock-screen / banner surface. Bigger than expanded leading
        /// since it has the full banner width to breathe.
        case banner
    }

    let phase: CaptureActivityAttributes.Phase
    let animationPhase: Double
    let size: Size
    var tint: Color = .white

    /// Base widths as ratios of the available width. Tuned to echo the
    /// AppIcon (top short with bullet, middle full, bottom medium).
    private static let topRatio: CGFloat = 0.52
    private static let midRatio: CGFloat = 1.00
    private static let botRatio: CGFloat = 0.78

    /// ±13% modulation around the base width while processing.
    private static let amplitude: CGFloat = 0.13

    /// Per-line phase offsets in radians. Top = 0, middle = π/3,
    /// bottom = 2π/3 — gives a "dancing" feel rather than a synchronised
    /// pulse.
    private static let topOffset: Double = 0
    private static let midOffset: Double = .pi / 3
    private static let botOffset: Double = 2 * .pi / 3

    var body: some View {
        GeometryReader { geo in
            let metrics = Metrics(size: size, in: geo.size)
            VStack(alignment: .leading, spacing: metrics.gap) {
                line(
                    baseRatio: Self.topRatio,
                    phaseOffset: Self.topOffset,
                    availableWidth: geo.size.width,
                    metrics: metrics,
                    showBullet: true
                )
                line(
                    baseRatio: Self.midRatio,
                    phaseOffset: Self.midOffset,
                    availableWidth: geo.size.width,
                    metrics: metrics,
                    showBullet: false
                )
                line(
                    baseRatio: Self.botRatio,
                    phaseOffset: Self.botOffset,
                    availableWidth: geo.size.width,
                    metrics: metrics,
                    showBullet: false
                )
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .frame(width: defaultWidth, height: defaultHeight)
        .accessibilityHidden(true)
    }

    // MARK: - Per-line drawing

    @ViewBuilder
    private func line(
        baseRatio: CGFloat,
        phaseOffset: Double,
        availableWidth: CGFloat,
        metrics: Metrics,
        showBullet: Bool
    ) -> some View {
        let width = lineWidth(
            baseRatio: baseRatio,
            phaseOffset: phaseOffset,
            availableWidth: availableWidth
        )
        HStack(spacing: metrics.bulletGap) {
            Capsule()
                .fill(tint)
                .frame(width: width, height: metrics.thickness)
            if showBullet {
                Circle()
                    .fill(tint)
                    .frame(width: metrics.thickness * 1.05, height: metrics.thickness * 1.05)
                    .opacity(phase == .processing ? bulletOpacity : 1)
            }
            Spacer(minLength: 0)
        }
    }

    /// Oscillates each line's width around its base. Amplitude is
    /// capped so the longest line never clips and the shortest line
    /// stays a recognisable shape (no shrinking to a dot).
    private func lineWidth(
        baseRatio: CGFloat,
        phaseOffset: Double,
        availableWidth: CGFloat
    ) -> CGFloat {
        guard phase == .processing else {
            return availableWidth * baseRatio
        }
        let wave = sin(animationPhase + phaseOffset)
        let modulated = baseRatio + CGFloat(wave) * Self.amplitude * baseRatio
        let clamped = min(max(modulated, 0.20), 1.0)
        return availableWidth * clamped
    }

    /// Bullet pulses opacity in sympathy with the lines. Half-frequency
    /// of the lines (we just halve the phase) so it reads as a separate
    /// beat, not a metronome locked to the top line.
    private var bulletOpacity: Double {
        let wave = sin(animationPhase * 0.5)
        return 0.55 + 0.45 * (wave * 0.5 + 0.5) // 0.55 ... 1.0
    }

    // MARK: - Layout metrics per size

    private struct Metrics {
        let thickness: CGFloat
        let gap: CGFloat
        let bulletGap: CGFloat

        init(size: Size, in box: CGSize) {
            switch size {
            case .compactLeading:
                self.thickness = 2.4
                self.gap = 2.0
                self.bulletGap = 2.0
            case .minimal:
                self.thickness = 2.2
                self.gap = 1.8
                self.bulletGap = 1.8
            case .expandedLeading:
                self.thickness = 4.5
                self.gap = 4.0
                self.bulletGap = 4.0
            case .banner:
                self.thickness = 6.0
                self.gap = 6.0
                self.bulletGap = 6.0
            }
        }
    }

    private var defaultWidth: CGFloat {
        switch size {
        case .compactLeading:   return 22
        case .minimal:          return 18
        case .expandedLeading:  return 56
        case .banner:           return 84
        }
    }

    private var defaultHeight: CGFloat {
        switch size {
        case .compactLeading:   return 18
        case .minimal:          return 16
        case .expandedLeading:  return 36
        case .banner:           return 52
        }
    }
}

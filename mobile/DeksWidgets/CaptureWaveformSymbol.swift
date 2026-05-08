import SwiftUI

/// SF Symbol replacement for the custom 3-line view inside the Dynamic
/// Island. Exists because `TimelineView(.animation)` does NOT drive
/// continuous motion in the *compact* island view — iOS renders that slot
/// as a static snapshot. SF Symbol effects (`.symbolEffect`) DO animate
/// in compact, so the user actually sees motion while a capture is
/// in-flight.
///
/// Trade-off vs `CaptureLogoLines`:
///   - We lose continuity with the AppIcon's three-line motif.
///   - We gain a glyph that visibly animates in the always-visible pill,
///     which is the surface the user spends 99% of their time reading.
///
/// The `phase` drives both the symbol and whether motion is applied:
///   - `.processing`: `waveform` with `.variableColor.iterative.reversing`
///     looping forever. White, hierarchical rendering for richer contrast.
///   - `.complete`:   `checkmark` glyph, soft green tint, no animation.
///   - `.failed`:     `exclamationmark.triangle.fill`, muted red, no animation.
///
/// Keep this view tiny — it gets called from compactLeading, minimal,
/// expandedLeading, AND the lock-screen banner, each at a different size.
struct CaptureWaveformSymbol: View {
    enum Slot {
        /// ~22pt wide leading region of the compact pill. Small.
        case compactLeading
        /// Even smaller — when another activity sits on the trailing side.
        case minimal
        /// Expanded leading region (post tap-and-hold). Big enough to feel
        /// premium without crowding the status text.
        case expandedLeading
        /// Lock-screen banner. Plenty of room.
        case banner
    }

    let phase: CaptureActivityAttributes.Phase
    let slot: Slot

    var body: some View {
        Group {
            switch phase {
            case .processing:
                processingSymbol
            case .complete:
                completeSymbol
            case .failed:
                failedSymbol
            }
        }
        .frame(width: frameWidth, height: frameHeight)
        .accessibilityHidden(true)
    }

    // MARK: - Per-phase symbols

    /// Active capture. `.variableColor.iterative.reversing` cycles the
    /// brightness through the waveform's bars, so it reads as a left-to-right
    /// "scrub" that bounces back. `.repeating` keeps it looping for the
    /// full life of the activity (iOS 17 form; `.repeat(.continuous)` is
    /// iOS 18+, which we can't require yet).
    ///
    /// Note: the iOS Simulator caches the compact Dynamic Island as a
    /// static snapshot, so this won't appear to animate when scripted
    /// against the sim. Apple's own first-party apps (Music, Voice Memos)
    /// use this same pattern and the animation IS visible on real
    /// hardware. We verify on the user's iPhone post-ship.
    private var processingSymbol: some View {
        Image(systemName: "waveform")
            .font(.system(size: glyphSize, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
            .symbolEffect(
                .variableColor.iterative.reversing,
                options: .repeating
            )
    }

    /// Settled success. Holding the same waveform with a green tint felt
    /// noisy at 22pt (the bars blur into one another), so we swap to a
    /// checkmark — instantly readable, matches the StatusPip's flip to green.
    private var completeSymbol: some View {
        Image(systemName: "checkmark")
            .font(.system(size: glyphSize, weight: .bold))
            .foregroundStyle(completeTint)
    }

    /// Settled failure. Triangle.fill is the iOS-native warning glyph and
    /// reads at any size; tinted muted red so it doesn't scream after the
    /// fact (the dialog is already telling the user what went wrong).
    private var failedSymbol: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(failedTint)
    }

    // MARK: - Sizing

    /// Glyph point size. SF Symbols scale with `.font(.system(size:))` and
    /// the bounds adjust to the chosen weight. Tuned by eye against the
    /// previous 3-line view so visual weight stays roughly consistent.
    private var glyphSize: CGFloat {
        switch slot {
        case .compactLeading:  return 18
        case .minimal:         return 16
        case .expandedLeading: return 36
        case .banner:          return 44
        }
    }

    private var frameWidth: CGFloat {
        switch slot {
        case .compactLeading:  return 22
        case .minimal:         return 18
        case .expandedLeading: return 60
        case .banner:          return 68
        }
    }

    private var frameHeight: CGFloat {
        switch slot {
        case .compactLeading:  return 18
        case .minimal:         return 16
        case .expandedLeading: return 38
        case .banner:          return 50
        }
    }

    // MARK: - Tints

    /// Soft green for the settled success state. Pulled to be visible on
    /// the dark Dynamic Island pill without screaming.
    private var completeTint: Color {
        Color(red: 0.42, green: 0.86, blue: 0.55)
    }

    /// Muted red. Same reasoning — visible without being alarmist.
    private var failedTint: Color {
        Color(red: 0.96, green: 0.46, blue: 0.46)
    }
}

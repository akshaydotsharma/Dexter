import SwiftUI

/// The voice overlay's background field (issue #429): five soft orange-to-green
/// blobs drifting on independent orbits and displaced by the user's voice.
///
/// ### Why five blobs and not a gradient
///
/// A two-stop gradient can only slide, which reads as a moving texture rather
/// than a living field. Five radial fills on different periods never repeat the
/// same arrangement, so the motion stays organic across a capture.
///
/// `MeshGradient` would be the obvious tool and it is iOS 18; this target is
/// 17.0. Blurred `RadialGradient` circles get there with no raised deployment
/// target, and because each blob is a separate composited layer the blur is GPU
/// work rather than per-pixel Swift.
///
/// ### Why it moves with the waveform
///
/// Each blob reads a DIFFERENT tap off the same `VoiceLevelTrace` the bars read
/// (`Blob.traceTap`). A syllable therefore brightens the bars and then pushes
/// the field outward a beat later, staggered across the five, so the whole
/// screen breathes as one thing instead of two animations sharing a screen. In a
/// gap the orbit continues on its own, so silence looks becalmed rather than
/// switched off.
///
/// ### Legibility
///
/// The transcript sits on top of this. `verticalFalloff` masks the field to full
/// strength through the animation zone and a trace by the time it reaches the
/// text, which is what keeps the live transcript readable at Full intensity.
struct VoiceAurora: View {

    /// 0 disables the field entirely; 1 is full strength. Exposed so the whole
    /// treatment can be dialled back after device review without touching the
    /// composition.
    var intensity: Double = 1.0

    /// Reads the CURRENT amplitude history, per frame. A closure for the same
    /// reason as `VoiceWaveform.trace`: taken by value, it froze at the parent's
    /// last body evaluation. The orbit is driven by `context.date` so the field
    /// still drifted convincingly, which is exactly why this went unnoticed here
    /// while the same bug was obvious in the waveform (issue #429).
    var trace: () -> VoiceLevelTrace
    /// Fades the whole field out for states where the mic isn't open, so the
    /// screen calms down while the AI call runs.
    var isActive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// One drifting field. Positions are unit coordinates in the container.
    private struct Blob {
        let colour: Color
        let origin: UnitPoint
        let radius: CGFloat      // fraction of the container's width
        let period: Double       // seconds for one orbit
        let phase: Double
        let drift: CGFloat       // orbit amplitude, fraction of the container
        let traceTap: Int        // frames of delay into the shared level trace
    }

    /// Orange through green. The two ends are `Tokens.accentNotes` and
    /// `Tokens.accentFinance` dark-mode values; a background wash needs the
    /// luminous variant of a token in BOTH schemes, because the muted light
    /// values disappear against warm paper.
    private var blobs: [Blob] {
        [
            Blob(colour: Color(hex: 0xF97316), origin: UnitPoint(x: 0.28, y: 0.18),
                 radius: 0.86, period: 11.0, phase: 0.0, drift: 0.16, traceTap: 2),
            Blob(colour: Color(hex: 0xF59E0B), origin: UnitPoint(x: 0.76, y: 0.28),
                 radius: 0.74, period: 14.5, phase: 1.7, drift: 0.13, traceTap: 8),
            Blob(colour: Color(hex: 0xA3E635), origin: UnitPoint(x: 0.50, y: 0.44),
                 radius: 0.94, period: 9.2, phase: 3.1, drift: 0.18, traceTap: 0),
            Blob(colour: Color(hex: 0x10B981), origin: UnitPoint(x: 0.16, y: 0.56),
                 radius: 0.72, period: 16.8, phase: 4.4, drift: 0.11, traceTap: 14),
            Blob(colour: Color(hex: 0x2DD4BF), origin: UnitPoint(x: 0.84, y: 0.64),
                 radius: 0.68, period: 12.6, phase: 5.9, drift: 0.14, traceTap: 20)
        ]
    }

    /// Warm paper needs a lighter touch than the dark ground, where the same
    /// wash reads as a glow rather than a stain.
    ///
    /// These are far higher than the first cut (0.42 / 0.30), which looked right
    /// in a browser prototype and arrived on device as a barely-visible smudge.
    /// Two things ate it that the prototype didn't model: SwiftUI's `.blur`
    /// spreads a fixed amount of colour over a much larger area than a canvas
    /// upscale does, and the vertical mask then multiplied what was left.
    private var baseOpacity: Double {
        colorScheme == .dark ? 0.95 : 0.62
    }

    /// On the dark ground the blobs are composited additively, so overlaps
    /// bloom into hot centres and the field reads as emitted light rather than
    /// as paint. On warm paper additive would just wash everything to white, so
    /// there it stays normal source-over.
    private var blend: BlendMode {
        colorScheme == .dark ? .plusLighter : .normal
    }

    /// Per-blob core alpha. Lower in dark because `.plusLighter` accumulates:
    /// five blobs at full strength would clip to white wherever they cross.
    private var coreAlpha: Double {
        colorScheme == .dark ? 0.62 : 1.0
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if reduceMotion {
                    // Still frame at a representative moment. The field is
                    // atmosphere, not information, so freezing it loses nothing.
                    field(in: geo.size, time: 3.2, trace: nil)
                } else {
                    // 20fps, not 30. This is five full-screen blurred gradients;
                    // at 30 it shared a frame budget with the waveform's own
                    // timeline and the two together starved the main thread
                    // while audio was streaming (issue #429). The field drifts
                    // slowly enough that 20 is indistinguishable.
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: intensity <= 0)) { context in
                        field(
                            in: geo.size,
                            time: context.date.timeIntervalSinceReferenceDate,
                            trace: trace()
                        )
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .mask(verticalFalloff)
            .opacity(intensity * (isActive ? 1 : 0.35))
            .animation(.easeInOut(duration: 0.45), value: isActive)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }

    /// `trace: nil` renders the reduce-motion still frame at a representative
    /// energy rather than reading live audio.
    private func field(in size: CGSize, time: Double, trace: VoiceLevelTrace?) -> some View {
        ZStack {
            ForEach(Array(blobs.enumerated()), id: \.offset) { _, blob in
                let energy = trace.map { CGFloat($0.normalizedLevel(delayedBy: blob.traceTap)) } ?? 0.45
                let angle = (time / blob.period) * 2 * .pi + blob.phase
                let dx = (cos(angle) * blob.drift + cos(angle * 1.7) * energy * 0.10) * size.width
                let dy = (sin(angle * 0.8) * blob.drift * 0.7 + sin(angle * 1.3) * energy * 0.07) * size.height
                let diameter = size.width * blob.radius * (1 + 0.35 * energy)

                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(stops: [
                                .init(color: blob.colour.opacity(coreAlpha), location: 0),
                                .init(color: blob.colour.opacity(coreAlpha * 0.58), location: 0.48),
                                .init(color: blob.colour.opacity(0), location: 1)
                            ]),
                            center: .center,
                            startRadius: 0,
                            endRadius: diameter / 2
                        )
                    )
                    .frame(width: diameter, height: diameter)
                    .position(
                        x: blob.origin.x * size.width + dx,
                        y: blob.origin.y * size.height + dy
                    )
                    .blendMode(blend)
                    // Springs the swell so a syllable pushes the field rather
                    // than making it flicker.
                    .animation(.spring(response: 0.42, dampingFraction: 0.78), value: energy)
            }
        }
        // Rasterise the whole field offscreen through Metal, once per tick.
        // This both isolates the additive blending (which must resolve within
        // this stack, not against the app's background, or `.plusLighter` would
        // wash the whole screen) and moves the blur off the CPU. Composites the
        // five gradients as a single texture instead of five layered passes.
        .drawingGroup(opaque: false)
        // Softer than the first cut (0.14). A wider blur spreads the same
        // colour over more area, which is most of why this arrived dim.
        .blur(radius: size.width * 0.085)
        .saturation(1.15)
        .opacity(baseOpacity)
    }

    /// Quiet behind the transcript, full strength behind the waveform.
    ///
    /// This runs top-light / bottom-heavy because the transcript sits ABOVE the
    /// waveform. It was the other way round when the waveform was on top; if
    /// those two ever swap back, this has to swap with them, or the live text
    /// ends up sitting on the brightest part of the field and stops being
    /// readable at full intensity.
    private var verticalFalloff: some View {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .black.opacity(0.30), location: 0.00),
                .init(color: .black.opacity(0.26), location: 0.30),
                .init(color: .black.opacity(0.55), location: 0.52),
                .init(color: .black, location: 0.74),
                .init(color: .black.opacity(0.80), location: 1.00)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

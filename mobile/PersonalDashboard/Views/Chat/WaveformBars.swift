import SwiftUI

/// Three short bars that bob continuously to suggest live audio. Decorative
/// only — height is time-driven, not bound to actual mic levels (the
/// transcriber doesn't expose levels), so it reads as "active" without
/// implying a meter. Shared by the inline chat `ListeningIndicator` and the
/// global voice-capture overlay (issue #150).
struct WaveformBars: View {
    private let barWidth: CGFloat = 3
    private let baseHeight: CGFloat = 6
    private let maxHeight: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                bar(height: height(t: t, period: 0.62, phase: 0.0))
                bar(height: height(t: t, period: 0.48, phase: 1.1))
                bar(height: height(t: t, period: 0.70, phase: 2.0))
            }
            .frame(height: maxHeight)
        }
    }

    private func bar(height: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(Tokens.danger.opacity(0.8))
            .frame(width: barWidth, height: height)
    }

    private func height(t: Double, period: Double, phase: Double) -> CGFloat {
        let s = (sin(2 * .pi * t / period + phase) + 1) / 2  // 0...1
        return baseHeight + (maxHeight - baseHeight) * CGFloat(s)
    }
}

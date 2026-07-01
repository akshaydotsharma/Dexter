import SwiftUI

// MARK: - User bubble

struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 24)
            Text(text)
                .font(.edBody)
                .foregroundStyle(Tokens.paper)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Tokens.ink)
                .clipShape(BubbleShape())
                .frame(maxWidth: 480, alignment: .trailing)
                .textSelection(.enabled)
        }
    }
}

// MARK: - AI prose (no bubble)

struct AIProse: View {
    let text: String
    var body: some View {
        if text.isEmpty {
            EmptyView()
        } else {
            // Markdown is rendered block-by-block so headings, lists, and
            // bold inline elements show up the way the model intended rather
            // than as raw `**` / `##` characters.
            MarkdownView(text: text)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Typing indicator

struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // A single, fixed reference date. Each frame's offset is derived from the
    // elapsed time since this date, not from an animatable @State property.
    // This sidesteps the SwiftUI endpoint-interpolation trap: an implicit/
    // explicit animation on a plain State value only interpolates between its
    // start and end values, so a full sin() cycle (which starts and ends at
    // ~0) collapses to a visually static offset even while "running". Driving
    // the curve from TimelineView's sampled date instead means there are no
    // endpoints to interpolate between — every tick recomputes sin() fresh
    // from continuous elapsed time, so the dots actually move on-device.
    private let start = Date()

    var body: some View {
        Group {
            if reduceMotion {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(Tokens.muted)
                            .frame(width: 6, height: 6)
                    }
                }
            } else {
                TimelineView(.animation) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(start)
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(Tokens.muted)
                                .frame(width: 6, height: 6)
                                .offset(y: dotOffset(elapsed: elapsed, index: i))
                        }
                    }
                }
            }
        }
        .frame(height: 16)
        .accessibilityLabel("Assistant is typing")
    }

    /// Staggered bob: each dot lags the previous by a fixed phase so the
    /// motion reads as a wave sweeping left to right, the classic
    /// typing-indicator look.
    private func dotOffset(elapsed: TimeInterval, index: Int) -> Double {
        let period = 0.9
        let stagger = 0.15
        let t = (elapsed - Double(index) * stagger) / period * (.pi * 2)
        return sin(t) * 3
    }
}

// MARK: - Success row (after a confirmed draft)

struct SuccessRow: View {
    let label: String
    var onView: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Tokens.success)
            Text(label)
                .font(.edFootnote)
                .foregroundStyle(Tokens.inkSoft)
            if let onView {
                Button("View →", action: onView)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.ink)
            }
        }
    }
}

// MARK: - Example prompt chip

struct ExampleChip: View {
    let text: String
    var action: () -> Void

    var body: some View {
        Button(text, action: action)
            .buttonStyle(EdChipStyle())
    }
}

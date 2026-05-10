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
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Tokens.muted)
                    .frame(width: 6, height: 6)
                    .offset(y: reduceMotion ? 0 : sin((phase + Double(i) * 0.33) * .pi * 2) * 3)
            }
        }
        .frame(height: 16)
        .accessibilityLabel("Assistant is typing")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
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

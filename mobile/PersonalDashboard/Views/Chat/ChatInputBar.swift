import SwiftUI

/// Floating input bar pinned to the bottom safe area inset.
struct ChatInputBar: View {
    @Binding var text: String
    var isSending: Bool
    var onSend: () -> Void
    var onMic: (() -> Void)? = nil
    /// True while `SpeechTranscriber` is actively listening. Swaps the mic
    /// glyph for a stop indicator and tints it `Tokens.danger` so the user
    /// has a clear "tap again to stop" affordance (issue #83).
    var isMicActive: Bool = false

    /// Owned by the parent so the parent can auto-focus the input when the
    /// chat surface becomes active (issue #48 — tapping the chat icon should
    /// land in the keyboard-up state). The parent declares
    /// `@FocusState private var inputFocused: Bool` and passes `$inputFocused`.
    @FocusState.Binding var focused: Bool

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSend = !trimmed.isEmpty && !isSending

        HStack(alignment: .bottom, spacing: Space.sm) {
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text("Ask anything…")
                        .font(.edBody)
                        .foregroundStyle(Tokens.mutedSoft)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text, axis: .vertical)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1...6)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 10)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit {
                        if canSend { onSend() }
                    }
            }
            .frame(minHeight: 40)

            if let onMic {
                Button(action: onMic) {
                    Image(systemName: isMicActive ? "stop.fill" : "mic")
                        .symbolRenderingMode(.monochrome)
                }
                .buttonStyle(EdIconButtonStyle(tint: isMicActive ? Tokens.danger : Tokens.muted))
                .accessibilityLabel(isMicActive ? "Stop voice input" : "Voice input")
                .accessibilityAddTraits(isMicActive ? .isSelected : [])
            }

            Button {
                onSend()
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(EdSendButtonStyle(enabled: canSend))
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.sm)
        .background(
            Tokens.surface,
            in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        )
        .paperBorder(focused ? Tokens.borderStrong : Tokens.border, radius: Radius.xl)
        .shadowSm()
    }
}

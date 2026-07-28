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
                    // Strip the default macOS bordered field box so the input
                    // reads as a single rounded surface (no box-in-a-box,
                    // issue #285), and the focus ring with it (#368). No-op on
                    // iOS, where the field is borderless.
                    .paperFieldOnMac()
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
                    // macOS: Shift-Return must insert a line break, not send.
                    //
                    // `.onSubmit` fires on macOS for BOTH Return and
                    // Shift-Return, so there was no way to write a multi-line
                    // chat message on the Mac at all (issue #299). Note the
                    // original diagnosis was the opposite, that Return did not
                    // send because `.submitLabel` is iOS-only; the user checked
                    // and Return works. Only the modifier case is broken.
                    //
                    // Deliberately additive, so the working path cannot regress:
                    // plain Return returns `.ignored` and falls through to the
                    // `.onSubmit` above, untouched. Only Shift-Return is claimed.
                    // If `.onKeyPress` turns out not to see the event before the
                    // field does, the failure mode is the current behaviour
                    // rather than a new one.
                    //
                    // Known limitation: this appends the newline rather than
                    // inserting at the caret, because SwiftUI's `TextField`
                    // exposes no selection. Correct for the common case of
                    // typing at the end; a mid-string caret would see the break
                    // land at the end. Fixing that properly needs the AppKit
                    // route `MacClearTextField` already takes, which is a larger
                    // change than this bug warrants.
                    #if os(macOS)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        text += "\n"
                        return .handled
                    }
                    #endif
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

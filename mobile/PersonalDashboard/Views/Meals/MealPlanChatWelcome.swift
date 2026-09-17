import SwiftUI

/// What an empty "What should I eat?" conversation shows (#606).
///
/// ### Why there is anything here at all
///
/// #602 took the explainer and the three example prompts off this screen, and
/// that was right: a chat that opens onto a paragraph about itself is a chat you
/// have to read past before you can type. What it left was a title, a caret and
/// nothing else, which is correct and cold — the screen said nothing about what
/// it was for.
///
/// This is the other answer. One mark, one sentence, and an arrival that makes
/// the screen feel answered rather than empty. It is DECORATION, not
/// instruction: there is nothing to read past, nothing to tap, and it is gone
/// the moment the first message is sent.
///
/// ### Why the greeting arrives rather than appearing
///
/// The dots come first and the sentence replaces them, which is the same
/// sequence every reply in this chat follows. That makes the greeting read as
/// Dexter's first turn instead of as a label printed on the background, and it
/// is the cheapest way to say "there is somebody here" without saying it in
/// words.
///
/// Reduce Motion gets the sentence immediately, with no dots stage and no pulse.
/// The animation is the whole of what it removes; none of the content is behind
/// it.
struct MealPlanChatWelcome: View {

    /// Drawn smaller in the macOS panel, which is a corner of a window rather
    /// than a whole screen.
    var compact: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// False until the dots have had their turn. Not a `Phase` enum: there are
    /// exactly two states and the second one is terminal.
    @State private var greeted = false

    /// How long the dots run before the sentence lands. Long enough to be read
    /// as thinking, short enough that nobody waits for it.
    private static let dotsDuration: Duration = .milliseconds(900)

    private var markSize: CGFloat { compact ? 56 : 76 }
    private var glyphSize: CGFloat { compact ? 24 : 32 }

    var body: some View {
        VStack(spacing: compact ? Space.md : Space.lg) {
            mark

            ZStack {
                if greeted {
                    greeting
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    TypingIndicator()
                        .transition(.opacity)
                }
            }
            // Holds the block's height steady across the swap, so the mark above
            // does not jump up the screen as the sentence arrives.
            .frame(minHeight: compact ? 44 : 64)
        }
        .padding(.horizontal, Space.lg)
        .frame(maxWidth: 340)
        .task {
            guard !reduceMotion else {
                greeted = true
                return
            }
            try? await Task.sleep(for: Self.dotsDuration)
            withAnimation(.easeOut(duration: 0.28)) { greeted = true }
        }
    }

    // MARK: - The mark

    /// A plate, breathing.
    ///
    /// The section accent at a wash rather than at full strength: this is the
    /// quietest thing on the screen by design, and a saturated disc in the
    /// middle of an empty page would be the loudest. The ring pulses on a
    /// continuous clock rather than on an animated `@State` value, for the
    /// reason `TypingIndicator` spells out — an implicit animation over a full
    /// sine cycle interpolates between two nearly equal endpoints and collapses
    /// to a still image on device.
    private var mark: some View {
        ZStack {
            if !reduceMotion {
                TimelineView(.animation) { timeline in
                    let elapsed = timeline.date.timeIntervalSince1970
                    let phase = sin(elapsed * 1.6)
                    Circle()
                        .strokeBorder(Tokens.accent(for: .meals).opacity(0.18), lineWidth: 1)
                        .frame(width: markSize, height: markSize)
                        .scaleEffect(1 + 0.06 * phase)
                        .opacity(0.5 + 0.3 * (1 - phase))
                }
            }

            Circle()
                .fill(Tokens.accent(for: .meals).opacity(0.10))
                .frame(width: markSize, height: markSize)

            Image(systemName: "fork.knife")
                .font(.system(size: glyphSize, weight: .regular))
                .foregroundStyle(Tokens.accent(for: .meals))
        }
        .frame(width: markSize * 1.2, height: markSize * 1.2)
        .accessibilityHidden(true)
    }

    // MARK: - The greeting

    /// Two lines, and the second one is the smaller claim.
    ///
    /// The first says who is here, the second says what to do with them. Neither
    /// is a list of example prompts: those were the part of the old explainer
    /// that made the screen read as homework.
    private var greeting: some View {
        VStack(spacing: Space.xs) {
            Text("Hi Akshay, I'm here to help with your meal plan.")
                .font(compact ? .edBodyMedium : .edHeading)
                .foregroundStyle(Tokens.ink)
            Text("Ask me what to eat and I'll suggest meals you can add to any day.")
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        // One element, read once. Two separate stops for a greeting nobody
        // navigates by is two stops between the reader and the field.
        .accessibilityElement(children: .combine)
    }
}

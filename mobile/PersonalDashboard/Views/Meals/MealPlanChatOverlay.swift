import SwiftUI

/// Fixed metrics for the floating chat (#599).
enum MealPlanChatMetrics {
    /// The floating button.
    static let buttonSize: CGFloat = 52
    /// Inset from the trailing edge of the tab. The BOTTOM inset comes from
    /// `BottomTabBarMetrics.fabBottomInset`, which already answers "clear the
    /// floating tab bar on a phone, sit in the true corner on a Mac" and is what
    /// every other floating button in this app uses.
    /// Widest the panel gets. Beyond this a chat line is too long to scan, and
    /// the plan behind it stops being visible, which is the whole reason this is
    /// a local overlay rather than a sheet.
    static let panelMaxWidth: CGFloat = 420
    /// Tallest the transcript gets before it scrolls inside the panel.
    ///
    /// The panel is a fixed box over the plan, so unlike the inline version it
    /// DOES own a scroll view. That is the trade a floating overlay makes: the
    /// content behind it stays put, and the price is one nested scroll.
    static let transcriptMaxHeight: CGFloat = 420
}

/// The plan chat: one button, two shapes (#599).
///
/// ### The phone gets a whole screen, the Mac gets a corner
///
/// They are not the same problem. A Mac window has room for a conversation
/// beside the plan, and keeping the plan visible while you talk about it is the
/// reason the panel is local. A phone has no beside: the same panel there is a
/// 380pt box with a transcript squeezed into a few lines, which is a chat you
/// fight rather than one you use.
///
/// So on iOS the button opens a full-screen conversation that behaves like every
/// other chat the user owns — a title, an X, the transcript, the field at the
/// bottom — and on macOS it stays the local overlay. Both run the same turns,
/// the same input and the same add path; only the container differs.
///
/// ### Why the old shape
///
/// The chat is a detour with a destination, and the destination is the plan
/// underneath it. A sheet hid the plan; an inline panel pushed it below the
/// fold. A floating button costs one corner and nothing else, and the panel it
/// opens covers part of the plan rather than all of it, so a suggestion can be
/// added and the tile filling in is visible in the same glance.
///
/// ### The scrim is a dismiss target, not a dimmer
///
/// It is nearly clear. Dimming the plan would undo the reason the panel is
/// local: the whole point is that the day stays readable while you talk about
/// it. What the scrim is FOR is a tap anywhere to close, which an overlay with
/// no backdrop cannot offer, so it is present, invisible, and hit-testable.
///
/// ### It writes nothing by itself
///
/// `onAdd` carries the day and the meal the card was set to, and it is the only
/// path from here to the store.
struct MealPlanChatOverlay: View {

    @Bindable var model: MealPlanChatModel

    /// The day a suggestion's picker starts on.
    let defaultDay: Date

    var onSend: () -> Void
    var onAdd: (MealPlanSuggestion, Date, MealType) -> Void

    @Binding var isOpen: Bool
    @FocusState private var inputFocused: Bool

    /// True when the greeting stands in for the transcript (#606).
    ///
    /// An error keeps the transcript on screen even with no turns, which is a
    /// real state: a send that fails before the first turn lands would otherwise
    /// swallow the reason and show a greeting instead.
    private var showsWelcome: Bool {
        model.isEmpty && model.errorMessage == nil
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            #if os(macOS)
            if isOpen {
                scrim
                panel
                    .padding(.trailing, Space.lg)
                    // Clears the button, which stays put underneath.
                    .padding(
                        .bottom,
                        BottomTabBarMetrics.fabBottomInset + MealPlanChatMetrics.buttonSize + Space.sm
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            #endif
            floatingButton
                .padding(.trailing, Space.lg)
                .padding(.bottom, BottomTabBarMetrics.fabBottomInset)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isOpen) {
            fullScreenChat
        }
        #endif
    }

    #if os(iOS)

    // MARK: - The phone's chat

    /// A conversation with nothing else on the screen.
    ///
    /// The transcript scrolls, the field is pinned under it and rises with the
    /// keyboard, and the way out is the X in the title row — the arrangement
    /// every chat app has settled on, which is worth more here than being
    /// different.
    private var fullScreenChat: some View {
        ZStack {
            Tokens.paper.canvasIgnoresSafeArea()

            VStack(spacing: 0) {
                fullScreenHeader
                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)

                if showsWelcome {
                    // Centred in what is left of the screen, not placed at the
                    // top of a scroll view that has nothing to scroll (#606).
                    MealPlanChatWelcome()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            MealPlanChatPanel(
                                model: model,
                                defaultDay: defaultDay,
                                onAdd: onAdd
                            )
                            .padding(Space.lg)
                        }
                        .onChange(of: model.turns.last?.text) { _, _ in scrollToNewest(proxy) }
                        .onChange(of: model.turns.count) { _, _ in scrollToNewest(proxy) }
                    }
                    .frame(maxHeight: .infinity)
                }

                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)
                inputRow
            }
        }
        .onAppear { inputFocused = true }
    }

    private var fullScreenHeader: some View {
        HStack(spacing: Space.sm) {
            Text("What should I eat?")
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: Space.sm)

            if !model.isEmpty {
                Button { model.reset() } label: {
                    Text("Clear").font(.edFootnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.muted)
                .accessibilityLabel("Clear this conversation")
            }

            Button {
                inputFocused = false
                isOpen = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.inkSoft)
                    .frame(width: 30, height: 30)
                    .background(Tokens.surface2, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close the meal chat")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    #endif

    // MARK: - The button

    /// Stays visible while the panel is open, and becomes the close control.
    ///
    /// One control in one place for both directions. A separate X inside the
    /// panel would put the way out somewhere different from the way in, and the
    /// glyph swap says which state you are in without a label.
    /// The chat button: a white disc carrying a speech bubble (#604).
    ///
    /// It was a dark circle carrying `sparkles`, which on a phone put it a
    /// centimetre from the capture button in the tab bar — same shape, same
    /// near-black fill, same glyph — so the two read as one control duplicated.
    /// The bubble says conversation rather than AI.
    ///
    /// It then spent a release in `accentMeals`, which is also the deep-link
    /// pulse colour, and it did not separate from the plan it floats over. The
    /// white disc does, in both themes, and it claims none of the section's
    /// palette. See `Tokens.mealChatFab` for why white rather than orange or
    /// violet, and why the disc does not follow the theme.
    ///
    /// The ground does NOT change when the panel opens. Only the glyph does. A
    /// control that changed colour on being pressed would read as a second
    /// control appearing where the first one was.
    private var floatingButton: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                isOpen.toggle()
            }
            if isOpen { inputFocused = true }
        } label: {
            Image(systemName: isOpen ? "xmark" : "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: isOpen ? 16 : 18, weight: .semibold))
                .foregroundStyle(Tokens.mealChatFabInk)
                .frame(
                    width: MealPlanChatMetrics.buttonSize,
                    height: MealPlanChatMetrics.buttonSize
                )
                .background(Tokens.mealChatFab, in: Circle())
                // The hairline is what keeps a white disc from dissolving into
                // the near-white card it can end up sitting over in light mode.
                // The shadow alone does that job on paper and not on a card.
                .overlay(Circle().strokeBorder(Tokens.borderStrong, lineWidth: 0.5))
                .shadowMd()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? "Close the meal chat" : "Ask what to eat")
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
    }

    #if os(macOS)

    // MARK: - The scrim

    private var scrim: some View {
        Color.black.opacity(0.001)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.2)) { isOpen = false }
            }
            .accessibilityHidden(true)
    }

    // MARK: - The panel

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Tokens.divider)
                .frame(height: 0.5)

            if showsWelcome {
                MealPlanChatWelcome(compact: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.xl)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        MealPlanChatPanel(
                            model: model,
                            defaultDay: defaultDay,
                            onAdd: onAdd
                        )
                        .padding(Space.lg)
                    }
                    .frame(maxHeight: MealPlanChatMetrics.transcriptMaxHeight)
                    .onChange(of: model.turns.last?.text) { _, _ in scrollToNewest(proxy) }
                    .onChange(of: model.turns.count) { _, _ in scrollToNewest(proxy) }
                }
            }

            Rectangle()
                .fill(Tokens.divider)
                .frame(height: 0.5)
            inputRow
        }
        .frame(maxWidth: MealPlanChatMetrics.panelMaxWidth)
        .background(Tokens.paper, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .paperBorder(Tokens.borderStrong, radius: Radius.xl)
        .shadowLg()
    }

    #endif

    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard let id = model.turns.last?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    #if os(macOS)
    private var header: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.mutedSoft)
            Text("What should I eat?").eyebrow()
            Spacer(minLength: 0)
            if !model.isEmpty {
                Button {
                    model.reset()
                } label: {
                    Text("Clear")
                        .font(.edCaption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.muted)
                .accessibilityLabel("Clear this conversation")
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }
    #endif

    private var inputRow: some View {
        HStack(spacing: Space.sm) {
            ChatInputBar(
                text: $model.draftInput,
                isSending: model.isSending,
                onSend: onSend,
                focused: $inputFocused
            )
            if model.isSending {
                Button {
                    model.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(EdIconButtonStyle(tint: Tokens.danger))
                .accessibilityLabel("Stop")
            }
        }
        .padding(Space.md)
    }
}

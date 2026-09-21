import SwiftUI

/// Fixed metrics for the floating chat (#599).
enum MealPlanChatMetrics {
    /// The floating button.
    ///
    /// Its inset from the trailing edge is each caller's own padding; the BOTTOM
    /// inset comes from `BottomTabBarMetrics.fabBottomInset`, which already
    /// answers "clear the floating tab bar on a phone, sit in the true corner on
    /// a Mac" and is what every other floating button in this app uses.
    static let buttonSize: CGFloat = 52

    /// Widest the panel gets. Beyond this a chat line is too long to scan, and
    /// the plan behind it stops being visible, which is the whole reason this is
    /// a local overlay rather than a sheet.
    static let panelMaxWidth: CGFloat = 420

    /// (macOS) What the panel has to leave free under itself: the floating
    /// button, the button's own bottom inset, and the gap between the two. It is
    /// both the panel's bottom padding and the first term subtracted from the
    /// window when its height is worked out, so the two can never disagree.
    static let panelBottomReserve: CGFloat =
        BottomTabBarMetrics.fabBottomInset + buttonSize + Space.sm

    /// (macOS) What it leaves free above itself, so a full-height panel still
    /// reads as a window floating over the plan rather than a second pane.
    static let panelTopMargin: CGFloat = Space.lg

    /// (macOS) Tallest the panel gets, however big the window is.
    ///
    /// The panel is a conversation ABOUT the plan, and a panel that grew with
    /// the window would eventually cover the thing being talked about. This is
    /// the vertical half of the argument `panelMaxWidth` makes.
    static let panelMaxHeight: CGFloat = 640

    /// (macOS) Shortest it gets, as long as the window has the room.
    ///
    /// Below roughly this the transcript is a few lines between a header and an
    /// input row, which is the shape #641 was filed about.
    static let panelMinHeight: CGFloat = 320

    /// (macOS) The panel's height for a given container height.
    ///
    /// Derived from the window rather than from the conversation, which is the
    /// whole point: the box used to hug its content, so it grew as turns landed,
    /// shrank when the transcript was cleared, and opened short and empty. A
    /// height that only changes when the window is resized gives the transcript
    /// a fixed frame to scroll inside, and that scroll is the trade a floating
    /// overlay makes — the plan behind it stays put, and the price is one nested
    /// scroll view.
    ///
    /// Bounded on both sides: never taller than the room above the button, and
    /// never shorter than `panelMinHeight` unless the window itself is too short
    /// to give it that, in which case it takes what there is rather than
    /// overflowing.
    static func panelHeight(inContainer containerHeight: CGFloat) -> CGFloat {
        let room = containerHeight - panelBottomReserve - panelTopMargin
        guard room > panelMinHeight else { return max(room, 0) }
        return min(room, panelMaxHeight)
    }
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

    /// A complaint from the camera, the photo library or the microphone (#631).
    ///
    /// Deliberately separate from `model.errorMessage`, which is what the TURN
    /// says went wrong. A photo that would not decode and a microphone with no
    /// permission are problems with the input: nothing has been sent, there is
    /// nothing to retry, and putting them in the transcript's error slot would
    /// describe a failed conversation that never happened.
    @State private var captureNotice: String?

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
                // The height comes from the window, not from the conversation
                // (#641). `GeometryReader` is what reads it: the panel is a
                // floating child of this ZStack, so nothing else here knows how
                // much room there is above the button.
                GeometryReader { geo in
                    panel
                        .frame(height: MealPlanChatMetrics.panelHeight(inContainer: geo.size.height))
                        .padding(.trailing, Space.lg)
                        // Clears the button, which stays put underneath.
                        .padding(.bottom, MealPlanChatMetrics.panelBottomReserve)
                        // A `GeometryReader` places its content top-leading, and
                        // this panel belongs in the opposite corner.
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
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
                Button {
                    model.reset()
                    captureNotice = nil
                } label: {
                    Text("Clear").font(.edFootnote)
                }
                .buttonStyle(.plain)
                // Discards the whole conversation with no undo, so it does not
                // get to look like the muted chrome around it (#645). The tint
                // lands here because `.plain` sets no foreground of its own —
                // unlike `EdButtonStyle`, where an outer `.foregroundStyle` is
                // silently overridden.
                .foregroundStyle(Tokens.danger)
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
                // Fills the space between the header and the input row rather
                // than sizing it. The panel's height is already settled, so a
                // greeting that hugged its own content would leave the box
                // half-empty with a gap under it (#641).
                MealPlanChatWelcome(compact: true)
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
                    // Takes whatever the header and the input row leave, instead
                    // of capping itself: the panel is a fixed box now, so the
                    // cap is the box (#641).
                    .frame(maxHeight: .infinity)
                    .onChange(of: model.turns.last?.text) { _, _ in scrollToNewest(proxy) }
                    .onChange(of: model.turns.count) { _, _ in scrollToNewest(proxy) }
                }
            }

            Rectangle()
                .fill(Tokens.divider)
                .frame(height: 0.5)
            inputRow
        }
        // Width only. The height is imposed from the body above, where the
        // window's size is known (#641).
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
                    captureNotice = nil
                } label: {
                    Text("Clear")
                        .font(.edCaption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.danger)
                .accessibilityLabel("Clear this conversation")
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }
    #endif

    /// The field, the two ways of filling it that are not typing, and the tray
    /// of what has been attached so far (#631).
    ///
    /// The tray sits ABOVE the bar rather than inside it. A thumbnail strip
    /// inside a control that already grows to six lines of text would push the
    /// send button around as photos come and go, and on the Mac the panel is a
    /// fixed box where that movement is the most visible thing on screen.
    private var inputRow: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let captureNotice {
                captureNoticeRow(captureNotice)
            }

            if !model.draftPhotos.isEmpty {
                MealPhotoStrip(photos: $model.draftPhotos)
                    .padding(.horizontal, Space.xs)
            }

            HStack(spacing: Space.sm) {
                ChatInputBar(
                    text: $model.draftInput,
                    isSending: model.isSending,
                    onSend: onSend,
                    focused: $inputFocused,
                    hasAttachments: !model.draftPhotos.isEmpty
                ) {
                    // The composer's own pair, at the input bar's scale. A
                    // photograph of a meal goes to the same model through the
                    // same compressor whichever surface it is attached on, so a
                    // second implementation here would be a second answer.
                    MealCaptureAccessories(
                        text: $model.draftInput,
                        photos: $model.draftPhotos,
                        onError: { captureNotice = $0 },
                        side: 40,
                        glyphSize: 18,
                        photoLabel: "Add a photo",
                        micLabel: "Dictate your question"
                    )
                }
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
        }
        .padding(Space.md)
        .animation(.easeOut(duration: 0.18), value: model.draftPhotos.count)
        .animation(.easeOut(duration: 0.18), value: captureNotice)
    }

    /// Same restrained inline note the main chat uses for a microphone failure:
    /// muted text on a surface, tap to dismiss, no alert.
    private func captureNoticeRow(_ message: String) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Tokens.muted)
            Text(message)
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
        .contentShape(Rectangle())
        .onTapGesture { captureNotice = nil }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Dismisses this message")
    }
}

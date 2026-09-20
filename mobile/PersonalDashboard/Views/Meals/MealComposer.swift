import SwiftUI
import SwiftData

/// What the composer is doing right now (#543).
enum MealComposerPhase: Equatable {
    case idle
    case estimating
    /// The estimate came back and has been checked. Nothing is written yet.
    case preview(CheckedMealEstimate)
    case failed(String)
}

/// What to do about a meal that looks like one already logged (#543).
enum MealDuplicateChoice: String, Identifiable {
    case keepBoth
    case replace
    case discard

    var id: String { rawValue }
}

/// The primary entry path: describe a meal, see the estimate, confirm it (#543).
///
/// ### Why there is no food search
///
/// There is no database lookup, no portion picker and no serving dropdown,
/// because the description IS the input. A search box turns "two eggs on toast
/// with butter and a flat white" into four separate lookups and four portion
/// decisions, which is the work the estimate exists to remove.
///
/// ### Why there is now a tray beside it (#625)
///
/// The rule above holds for food nobody knows the numbers of. It is the wrong
/// rule for a packet: a Farmers Union pot states its figures on the back, and
/// re-estimating it costs a call, a few seconds and a slightly different answer
/// every time, so two logs of one pot disagree and a week's protein is the sum
/// of the disagreement.
///
/// So there are exactly two ways to log a meal, and since #643 the composer
/// says so out loud: describe it in the field, or take the branch under it into
/// `FoodItemPickerSheet`. The word between them is "or" and the rule around it
/// is a fork, but both can still be used in the same meal. The tray is what has
/// been added so far, and the primary button reads what is in front of it:
///
/// 1. Text, no picks. "Estimate", exactly as it has always worked.
/// 2. Picks, no text. "Log". No call of any kind, and no preview: there is
///    nothing to preview, because nothing was guessed.
/// 3. Both. "Estimate", and the model is shown ONLY the typed words. The picks
///    are exact and are never sent anywhere.
///
/// ### Why there is a camera and a microphone on the field (#627)
///
/// Typing stays the primary path and nothing about it changed. What #627 added
/// is two other ways to answer the same question, for the two cases where words
/// are the slow way to say it: the meal is in front of you and a photograph
/// states it exactly, or your hands are busy and saying it is faster than
/// spelling it out.
///
/// Both feed the SAME field and the SAME call. The microphone writes into the
/// description, so a dictated meal is a typed meal that was not typed. The
/// photograph rides the estimate request as an image block, so a photographed
/// meal takes the same guards, the same preview and the same duplicate check a
/// described one does.
///
/// The photograph is NOT kept. It is an input, the description field's peer, and
/// `reset()` drops it exactly as it drops the text. See `MealPhoto` for the five
/// subsystems that decision buys back.
///
/// ### Why the preview is not optional
///
/// The estimate is a guess about portions, and the assumptions it made are the
/// only part of it a user can argue with. Writing straight to the log would mean
/// the first time anyone saw "assumed 10 g of butter" was after the day's totals
/// had already moved.
///
/// ### Why it names the day it writes to
///
/// The composer used to be on today alone, because one field and one button that
/// silently log to March is worse than no composer at all. #592 put it on every
/// day the calendar can reach, and the day label is what pays for that: on an
/// earlier day the eyebrow states the date before the estimate runs, and the
/// preview states it again beside the Log button. Both statements are load
/// bearing. Take them away and the today-only rule has to come back.
///
/// There is no day control here, and there must not be one. The calendar in the
/// section chrome is the single place a day is chosen, so a second control would
/// give the surface two answers to one question and no way to tell which one the
/// meal was written against.
struct MealComposer: View {
    /// The calendar day the meal will be logged against. Device-local.
    let day: Date

    /// Meals already on that day, for the soft duplicate check.
    let existingOnDay: [LocalMeal]

    let onLogged: (LocalMeal) -> Void

    @State private var descriptionText: String = ""
    /// Nil means "let the model infer it", which is the default: the
    /// description usually says, and a picker the user has to touch on every
    /// meal is friction on the one path that has to stay fast.
    @State private var typeOverride: MealType?
    @State private var phase: MealComposerPhase = .idle

    /// The meal type the preview's Log button will write (#643).
    ///
    /// Seeded from the model's answer the moment an estimate lands, and then
    /// owned by the user. It is separate from `typeOverride` on purpose:
    /// that one is a HINT sent with the request and the model is free to
    /// ignore it, this one is the decision. Conflating them would mean a user
    /// who corrected "lunch" to "dinner" in the preview had merely suggested it
    /// again to a call that had already finished.
    @State private var previewMealType: MealType = .lunch

    /// Items added to this meal from the picker, in the order they were added
    /// (#625).
    ///
    /// The whole tray is replaced by the picker rather than merged into, which
    /// is what makes Cancel in that sheet mean "nothing happened".
    ///
    /// A pick can name a row in the library or carry a database hit that is not
    /// saved yet. Nothing here has to tell them apart: `pickedItems` reads the
    /// entry either way, and `FoodItemPick.commit` resolves the origin once, at
    /// the write.
    @State private var picks: [FoodItemPick] = []
    @State private var showingPicker = false

    /// Photographs of this meal, held only until the estimate returns (#627).
    ///
    /// Composer state, exactly like `descriptionText`: they are an input, not an
    /// attachment. `reset()` clears them with the field, and nothing writes them
    /// anywhere. See `MealPhoto` for why they are not kept.
    @State private var photos: [MealPhoto] = []

    /// A complaint from the camera or the microphone, which is a different kind
    /// of failure from a failed estimate (#627).
    ///
    /// `phase = .failed` means "the model could not do this", and it offers Try
    /// again and Log it without numbers. A photo that would not decode and a
    /// microphone with no permission are neither: nothing has been sent, there
    /// is nothing to log, and both of those buttons would be answering a
    /// question nobody asked. So this is its own quiet line under the field.
    @State private var captureNotice: String?

    /// Meals the pending estimate duplicates. Non-empty puts the choice in
    /// front of the user; it never blocks the write.
    @State private var duplicateMatches: [LocalMeal] = []
    @State private var showingDuplicateChoice = false

    /// What the user has committed to, held while the duplicate dialog is up.
    ///
    /// It used to be read back off `phase`, which worked while an estimate was
    /// the only thing that could be written. A tray-only meal has no preview
    /// phase to read, so the intent is now stated once and held (#625).
    @State private var pendingWrite: PendingWrite?

    /// A write the user has asked for, waiting on the duplicate check.
    private enum PendingWrite {
        /// Paths 1 and 3: a checked estimate, plus whatever the tray holds.
        case estimate(CheckedMealEstimate)
        /// Path 2: the tray alone. There is no estimate, so the meal type is
        /// the only thing that had to be decided.
        case library(mealType: MealType)
    }

    @FocusState private var fieldFocused: Bool

    /// Writes go through the shared store, the same one every other surface
    /// uses. This view holds no `@Query` of its own: `MealsView` owns the day's
    /// rows and hands them down, so there is exactly one place that decides
    /// which day is on screen.
    private var service: MealEstimationService { .default() }

    private var trimmed: String {
        descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A description OR a photograph. Either one is a complete account of a
    /// meal, so requiring both would make the camera a decoration on a field
    /// you still had to fill in (#627).
    private var canEstimate: Bool {
        (!trimmed.isEmpty || !photos.isEmpty) && phase != .estimating
    }

    /// The added items as the value type a meal stores. The picker already
    /// scaled each one to the amount on its row, so nothing here multiplies
    /// anything.
    private var pickedItems: [MealItemEntry] {
        picks.map(\.entry)
    }

    /// What the primary button does, which is decided by what is in front of
    /// it and by nothing else (#625).
    private enum PrimaryAction {
        case estimate
        case logPicks
    }

    /// Picks with no description is the ONLY state that writes without a
    /// model call. An empty composer stays on Estimate, disabled, which is
    /// what it has always done.
    /// A photo counts as something to estimate, so a meal with picks AND a
    /// photograph stays on Estimate. Falling through to Log there would write
    /// the tray and silently drop the picture (#627).
    private var primaryAction: PrimaryAction {
        trimmed.isEmpty && photos.isEmpty && !picks.isEmpty ? .logPicks : .estimate
    }

    /// Whether the second way in is on screen.
    ///
    /// Idle and failed, yes: both are states where the card is still asking
    /// what the meal was, and after a failed estimate the picker is a genuine
    /// fallback. Estimating and preview, no. Removing a picked row stays
    /// possible either way, because each tray row carries its own control.
    private var showsBranch: Bool {
        switch phase {
        case .idle, .failed: return true
        case .estimating, .preview: return false
        }
    }

    /// Whether path 1's button is on screen.
    ///
    /// Gone once an estimate has come back: the preview owns the decision from
    /// then on, and a second Estimate above it would offer to re-run a call
    /// whose answer is already on screen.
    private var showsEstimateButton: Bool {
        switch phase {
        case .idle, .estimating: return true
        // A failed estimate offers its own Try again, so this would be a second
        // button for the same act.
        case .failed, .preview: return false
        }
    }

    /// Whether path 2's log row is on screen.
    ///
    /// Only when the tray is the whole meal. `primaryAction` already states
    /// that rule for the write; this reads the same property so the button and
    /// the write cannot disagree about which path a meal is on.
    private var showsPicksLogRow: Bool {
        showsBranch && !picks.isEmpty && primaryAction == .logPicks
    }

    /// The meal type a tray-only meal is written with: the user's choice, or
    /// the one the clock implies.
    private var libraryMealType: MealType {
        typeOverride ?? MealEstimationService.inferredType(at: estimateReferenceInstant())
    }

    /// What goes in `LocalMeal.mealDescription`.
    ///
    /// The typed words first, then the picks named with their amounts. Both
    /// halves, always: this field is what search, the duplicate check and a
    /// later re-estimate all read, and a description that named only the
    /// chicken rice would describe a meal the user did not eat.
    private func descriptionToWrite(for checked: CheckedMealEstimate?) -> String {
        let picked = MealEstimationService.libraryDescription(for: pickedItems)
        // A photographed meal with nothing typed has no words of its own, and
        // the photo is not kept, so the model's reading of it IS the record
        // (#627). Without this the row is written with an empty description,
        // which is the one field search, the duplicate check and a later
        // re-estimate all read.
        let spoken = trimmed.isEmpty && !photos.isEmpty && checked != nil
            ? MealEstimationService.libraryDescription(for: checked!.items)
            : trimmed
        if spoken.isEmpty { return picked }
        if picked.isEmpty { return spoken }
        return "\(spoken), \(picked)"
    }

    /// Derived from `day` rather than passed in, so the composer cannot disagree
    /// with itself about which day it is writing to.
    private var isToday: Bool {
        Calendar.current.isDateInToday(day)
    }

    /// The day in words, for the two places that state it (#592).
    ///
    /// Weekday and date together, not one or the other. The weekday is how
    /// anyone remembers a meal three days back, and the date is the only half
    /// that stays true a month later. The section chrome states the same day as
    /// "14 Sep", so the date here has to match it exactly or the two controls
    /// read as two different days.
    private var dayPhrase: String {
        Self.dayPhraseFormatter.string(from: day)
    }

    /// The field's eyebrow. Today keeps the original four words: the primary
    /// path is the one that must not grow, and on today there is no other day
    /// for the meal to land on.
    private var prompt: String {
        isToday ? "What did you eat?" : "What did you eat on \(dayPhrase)?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(prompt).eyebrow()

            field

            if let captureNotice {
                Text(captureNotice)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isStaticText)
            }

            // Directly under the field, because the photographs belong to it:
            // they are what the description would have said. Above the tray,
            // which is a different kind of input entirely — picked rows with
            // figures already on them.
            if !photos.isEmpty {
                MealPhotoStrip(photos: $photos, note: photoNote)
            }

            // The branch, and the second path under it (#643). Everything
            // above this line is one way of answering "what did you eat"; the
            // block below it is the other, and it ends in its own button.
            //
            // It is a way IN, so it is only on screen while the card is still
            // asking the question. Once an estimate is running or a preview is
            // up, the card has one job — wait, or confirm — and a live fork in
            // the middle of it is both noise and a tap target that would open a
            // picker onto a meal already being written.
            if showsBranch {
                orBranch
                    .frame(maxWidth: branchWidth)
                    .frame(maxWidth: .infinity, alignment: .center)

                findItemButton
                    .frame(maxWidth: branchWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // The tray sits under the button that fills it: it IS the second
            // path's input, and it stays editable while a preview is up.
            if !picks.isEmpty { trayBlock }

            // The second path's own log step (#643).
            //
            // It carries the meal type because this is the moment the meal is
            // written, and a picked tray has no opinion about whether it is
            // lunch. Nothing here is estimated, so nothing is previewed: the
            // numbers came off a label and the button writes them.
            //
            // It appears only when the tray is the WHOLE meal. With words in
            // the field the picks ride the estimate instead, and two live write
            // buttons would ask the user which of them their meal qualifies for.
            if showsPicksLogRow {
                HStack(alignment: .center, spacing: Space.sm) {
                    MealTypeDropdown(selection: $typeOverride)
                        .frame(maxWidth: 200)
                    logPicksButton
                }
                .frame(maxWidth: branchWidth)
                .frame(maxWidth: .infinity, alignment: .center)
            } else if !picks.isEmpty && showsBranch {
                // The tray is not the whole meal, so its Log button is gone and
                // the user is owed the reason. Without this the items look
                // stranded: added, listed, and with no button under them.
                Text("Added to the estimate when you press Estimate.")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: branchWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            switch phase {
            case .idle:
                EmptyView()
            case .estimating:
                estimatingRow
            case .preview(let checked):
                // One preview for both cases. With an empty tray it is the
                // #543 preview unchanged; with picks it grows a second,
                // labelled group. The alternative was a second preview built
                // here, which is the duplication #475 and #500 were.
                MealEstimatePreview(
                    checked: checked,
                    description: trimmed,
                    dayNote: isToday ? nil : "This logs onto \(dayPhrase), not today.",
                    savedItems: pickedItems,
                    // The model's answer, and the user's if they disagree with
                    // it (#643). This is the log step, so this is where the
                    // meal type is decided and where it is read from.
                    mealType: $previewMealType,
                    onDiscard: { reset() },
                    onConfirm: { confirm(checked) }
                )
            case .failed(let message):
                failureBlock(message)
            }
        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
        .sheet(isPresented: $showingPicker) {
            // The whole tray goes in and the whole tray comes back, so Cancel
            // in the picker leaves this one exactly as it was.
            FoodItemPickerSheet(initialPicks: picks) { chosen in
                picks = chosen
            }
        }
        .confirmationDialog(
            duplicateTitle,
            isPresented: $showingDuplicateChoice,
            titleVisibility: .visible
        ) {
            Button("Keep both") { resolveDuplicate(.keepBoth) }
            Button("Replace the earlier one", role: .destructive) { resolveDuplicate(.replace) }
            Button("Discard this one", role: .cancel) { resolveDuplicate(.discard) }
        } message: {
            Text("A similar \(duplicateMatches.first?.mealTypeEnum.displayName.lowercased() ?? "meal") was logged within the last two hours. Both rows stay flagged until you choose.")
        }
    }

    // MARK: - Input

    /// The example meal shown while the field is empty.
    ///
    /// A constant rather than a literal because macOS needs it in two places:
    /// the field's own title has to be EMPTY there, or AppKit draws this string
    /// at near-ink strength and the composer reads as pre-filled with a
    /// breakfast nobody ate (#576). `PlainFieldPlaceholder` owns both halves.
    static let placeholderExample = "Two eggs on toast with butter and a flat white"

    /// The description, with the camera and the microphone inside its border
    /// (#627).
    ///
    /// The two accessories are an overlay pinned to the bottom trailing corner,
    /// and `accessoryGutter` is the trailing padding that keeps the text off
    /// them. Without it the last line of a long description runs under the two
    /// glyphs.
    ///
    /// The gutter is charged on EVERY line, not only the line the buttons sit
    /// beside, because a uniform `.trailing` padding is the only version of this
    /// SwiftUI lays out without a custom `Layout`. It costs the field about 68pt
    /// of width on a phone. That is affordable here and it is measured: the
    /// example meal the placeholder advertises still fits, and the field grows to
    /// five lines before it has to truncate anything. If a future change makes
    /// the field single-line, revisit this — a one-line field cannot spend 68pt.
    private var field: some View {
        TextField(
            // Empty on both platforms, and its own placeholder drawn below. The
            // native one is vertically centred, which on a multi-line field puts
            // the example text nowhere near the caret (#627).
            PlainFieldPlaceholder.multilineTitle(Self.placeholderExample),
            text: $descriptionText,
            axis: .vertical
        )
        .font(.edBody)
        .foregroundStyle(Tokens.ink)
        // Three lines rather than two. A meal is usually a list — a main, a
        // side and a drink — and two lines meant the third scrolled out of a box
        // that had room to show it. It also gives the two accessories in the
        // bottom gutter somewhere to sit that is not beside the first line.
        .lineLimit(3...6)
        .textFieldStyle(.plain)
        .focused($fieldFocused)
        // The label belongs to the TEXT, and it has to be attached before the
        // accessory overlay goes on. Applied afterwards it labels the composed
        // view instead, which folds the camera and the microphone into one
        // element named "Describe the meal" — they stop being reachable by
        // VoiceOver and by anything scripting the app.
        .accessibilityLabel(isToday ? "Describe the meal" : "Describe the meal eaten on \(dayPhrase)")
        .onSubmit { if canEstimate { estimate() } }
        .padding(Space.md)
        .padding(.trailing, accessoryGutter)
        .multilinePlainFieldPlaceholder(
            Self.placeholderExample,
            isVisible: descriptionText.isEmpty,
            leading: Space.md,
            top: Space.md,
            trailing: Space.md + accessoryGutter
        )
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .stroke(Tokens.border, lineWidth: 0.5)
        )
        .overlay(alignment: .bottomTrailing) {
            // Three controls on one line, and they are the same kind of thing:
            // each one is a way of turning what is in this box into a meal
            // (#643). The plus and the microphone FILL the box; the arrow sends
            // it. Putting the arrow anywhere else made it look like it acted on
            // the whole card, which it never did.
            HStack(spacing: Space.xs) {
                MealCaptureAccessories(
                    text: $descriptionText,
                    photos: $photos,
                    // An estimate in flight has already been sent the field's
                    // contents, so editing them means editing something that was
                    // not asked. The preview and failure states stay editable,
                    // because both of those are states you argue with.
                    isEnabled: phase != .estimating,
                    onError: { captureNotice = $0 }
                )
                if showsEstimateButton {
                    estimateButton
                }
            }
            .padding(.trailing, Space.sm)
            .padding(.bottom, Space.sm)
        }
    }

    /// Room for the three accessory glyphs on the field's last line.
    ///
    /// Three 28pt buttons and two 4pt gaps, plus the 8pt the overlay is inset
    /// by. The Mac used to reserve one button's worth, because the microphone
    /// was iOS-only; it carries both since #640, so the gutter is the same on
    /// both platforms and a short reservation would let the last line run under
    /// a glyph.
    ///
    /// It reserves all three even in the phases that do not draw the arrow
    /// (#643). A gutter that changed with the phase would reflow every line of
    /// the description the moment an estimate came back, which is a paragraph
    /// moving under the user for no reason they can see.
    ///
    /// The cost is real and it is measured: on a phone this is about 100pt of a
    /// 338pt field, charged on every line rather than only the line the buttons
    /// sit beside, because a uniform `.trailing` padding is the only version of
    /// this SwiftUI lays out without a custom `Layout`. The field still opens at
    /// three lines and grows to six, so a meal has room. If a future change
    /// makes this field single-line, this arrangement cannot survive it: move
    /// the row below the text instead of over it.
    private var accessoryGutter: CGFloat {
        28 * 3 + Space.xs * 2 + Space.sm
    }

    /// The one thing worth saying under a photograph with no words beside it.
    ///
    /// It used to open by announcing that Dexter would read the meal from the
    /// photo, which is a sentence that tells the user what they just did. The
    /// thumbnail is directly above it and the button says Estimate; nobody needs
    /// the narration. What is actually worth saying is the part they cannot
    /// infer: that a portion or a brand the picture does not show is theirs to
    /// add, and this is the moment to add it.
    private var photoNote: String? {
        guard trimmed.isEmpty else { return nil }
        return "Add a line if a portion or a brand isn't obvious."
    }

    /// Path 1's action, and only path 1's (#643).
    ///
    /// ### Why it is a glyph and not the word "Estimate"
    ///
    /// It sits in the field's own accessory row, in line with the plus and the
    /// microphone, and those three are one family: a photograph, a spoken
    /// sentence and a typed one all end up as the same request. A labelled
    /// button in that row would be a fourth kind of thing wedged between two
    /// icons, and it would cost the row more width than the two inputs put
    /// together.
    ///
    /// The arrow is the one glyph that means "send this" without naming what
    /// happens next, which suits a control whose answer is a guess. The filled
    /// disc is what separates it from its two neighbours: they are outlined and
    /// quiet because they fill the box, this one is solid because it acts on it.
    ///
    /// ### Why it spins in place
    ///
    /// The word used to change to "Estimating…". With no word left, the disc
    /// carries the state itself: it holds its fill and swaps the arrow for a
    /// spinner, so the thing you pressed is the thing that is working.
    private var estimateButton: some View {
        Button {
            estimate()
        } label: {
            Group {
                if phase == .estimating {
                    ProgressView()
                        #if os(macOS)
                        .controlSize(.small)
                        #else
                        .scaleEffect(0.55)
                        #endif
                        // The spinner sits on a filled disc, so it has to be
                        // drawn in the paper the arrow would have been.
                        .tint(Tokens.paper)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            // The resting state is drawn to be SEEN, not to disappear. It
            // first used `paper2` on `mutedSoft`, which on this palette is
            // #F4F0E6 on a #F8F5EE field: four points of difference, so the
            // third control vanished and the field looked like it had only two.
            // A user who has not typed yet is exactly the user who needs to know
            // the arrow is there. So the disc rests on `border` with its arrow
            // in the same `muted` its two neighbours use, and fills with ink
            // only once it can act.
            .foregroundStyle(isLive ? Tokens.paper : Tokens.muted)
            .frame(width: 28, height: 28)
            .background(isLive ? Tokens.ink : Tokens.border, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canEstimate)
        .accessibilityLabel(phase == .estimating ? "Estimating the meal" : "Estimate the meal")
        .accessibilityHint(canEstimate || phase == .estimating ? "" : "Describe the meal or add a photo first")
    }

    /// Whether the disc is drawn filled.
    ///
    /// True while an estimate is running as well as when one can start.
    /// `canEstimate` is false mid-call — the inputs are not editable then — and
    /// reading it alone would drain the colour out of the control at the exact
    /// moment it is doing the work.
    private var isLive: Bool {
        canEstimate || phase == .estimating
    }

    /// Path 2's action: write the tray, with no call and no preview (#643).
    ///
    /// There is nothing to preview. The numbers were read off a packet and the
    /// amounts are the ones the user typed in the picker, so a preview would be
    /// asking them to confirm their own arithmetic.
    private var logPicksButton: some View {
        Button {
            commitPicksAlone()
        } label: {
            Text("Log meal")
        }
        .buttonStyle(EdButtonStyle(kind: .primary, size: .md, fullWidth: true))
        .disabled(phase == .estimating)
        .opacity(phase == .estimating ? 0.5 : 1)
    }

    /// The fork between the two ways to say what the meal is (#643).
    ///
    /// A rule with the word in the middle, and the word is the whole point: it
    /// says the thing above and the thing below are alternatives rather than
    /// steps. "Or", not "and", because either one alone is a complete meal —
    /// though nothing stops a user taking both, which is what path 3 in the
    /// type note above is.
    ///
    /// It is drawn from the same two tokens every other separator on this
    /// surface uses: a hairline in `Tokens.border`, and an eyebrow in the
    /// softest ink the palette has. Anything louder would read as a heading and
    /// split one card into two.
    private var orBranch: some View {
        HStack(spacing: Space.sm) {
            branchRule
            Text("or").eyebrow(Tokens.mutedSoft)
            branchRule
        }
        // One element, read once. Without this VoiceOver stops on two decorative
        // rules on the way past a two-letter word.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("or")
    }

    /// How wide the branch is allowed to get.
    ///
    /// On a phone the card is narrower than this, so the rule and the button
    /// fill it exactly as the field above them does. A Mac window is not: at
    /// full width the button becomes a 1,400pt bar with two words floating in
    /// the middle of it, which reads as an empty toolbar rather than as
    /// something to press.
    private let branchWidth: CGFloat = 420

    private var branchRule: some View {
        Rectangle()
            .fill(Tokens.border)
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
    }

    /// The second path, under the branch rather than in the control row (#643).
    ///
    /// It used to sit beside the meal-type dropdown, on the grounds that both
    /// are choices about WHAT is in the meal. That reasoning was right about the
    /// button and wrong about the row: the control row is where the meal is
    /// SETTLED — pick a type, press Estimate — so a third control in it read as
    /// a modifier on the description rather than as the alternative to writing
    /// one. Full width under an "or" states what it is in the one way nobody has
    /// to work out.
    ///
    /// It says "find", not "saved items". The sheet behind it searches the
    /// user's own items AND the public food database in one field, and calling
    /// it a saved list promised something to maintain (#625). The count is left
    /// off deliberately: the tray sits directly below this button whenever it
    /// has anything in it, so a number here would state twice what is already
    /// on screen.
    private var findItemButton: some View {
        Button {
            showingPicker = true
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "magnifyingglass")
                    // Sized off the ramp rather than off a literal, so the glyph
                    // keeps its proportion to the label on a Mac, where the body
                    // size is three points smaller than on the phone.
                    .font(.system(size: EdMetrics.bodyPointSize - 3, weight: .semibold))
                Text("Find an item")
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(EdButtonStyle(kind: .secondary, size: .md, fullWidth: true))
        .accessibilityLabel(picks.isEmpty
                            ? "Find an item to add"
                            : "Find an item to add, \(picks.count) added")
    }

    private var estimatingRow: some View {
        HStack(spacing: Space.sm) {
            ProgressView()
                #if os(macOS)
                .controlSize(.small)
                #else
                .scaleEffect(0.7)
                #endif
            Text("Reading the description and working out portions.")
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
        }
        .accessibilityElement(children: .combine)
    }

    /// A failed call must never cost the user the meal. The description stays in
    /// the field, and the row can still be written with no numbers at all.
    private func failureBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(message)
                .font(.edFootnote)
                .foregroundStyle(Tokens.danger)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.sm) {
                Button("Try again") { estimate() }
                    .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                if canLogWithoutNumbers {
                    Button("Log it without numbers") { logWithoutNumbers() }
                        .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
                }
            }
        }
    }

    // MARK: - The tray (#625)

    /// What has been added so far: one quiet line each, and a running total.
    ///
    /// Quiet on purpose. These rows are already settled — the numbers came off
    /// a label and nothing is going to change them — so they must not compete
    /// with the description field, which is the part still being written.
    private var trayBlock: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text("Items").eyebrow()
                Spacer(minLength: Space.sm)
                Text("\(MealFormat.calories(pickedCalories, .stated)) kcal")
                    .font(.edFootnoteStrong)
                    .foregroundStyle(Tokens.inkSoft)
                    .monospacedDigit()
            }
            ForEach(picks) { pick in
                trayRow(pick)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    /// Stated precision, not estimate precision. Rounding 148 to 150 would
    /// throw away the one property that makes the library worth keeping.
    private var pickedCalories: Double {
        pickedItems.reduce(0) { $0 + $1.calories }
    }

    private func trayRow(_ pick: FoodItemPick) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(pick.entry.name)
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            Text(pick.entry.portionDescription)
                .font(.edCaption)
                .foregroundStyle(Tokens.mutedSoft)
                .monospacedDigit()
            Text("\(MealFormat.calories(pick.entry.calories, .stated)) kcal")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .monospacedDigit()
            Button {
                picks.removeAll { $0.id == pick.id }
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Tokens.mutedSoft)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(pick.entry.name)")
        }
    }

    // MARK: - The preview for a meal that is part guessed (#625)


    // MARK: - Actions

    /// Path 2: the tray on its own.
    ///
    /// No call, no preview and no guard. There is nothing to preview, because
    /// nothing was guessed at: the user picked rows they had already read
    /// against a packet, and the amounts are the ones they typed in the picker.
    /// The duplicate check still runs, because logging the same breakfast twice
    /// is a mistake a saved item makes EASIER, not harder.
    private func commitPicksAlone() {
        let type = libraryMealType
        checkDuplicates(
            .library(mealType: type),
            mealType: type,
            description: MealEstimationService.libraryDescription(for: pickedItems)
        )
    }

    private func estimate() {
        guard canEstimate else { return }
        let description = trimmed
        let attached = photos
        let hint = typeOverride
        let at = estimateReferenceInstant()
        fieldFocused = false
        phase = .estimating
        Task {
            do {
                let checked = try await service.estimate(
                    description: description,
                    photos: attached,
                    mealTypeHint: hint,
                    loggedAt: at
                )
                // The model's answer becomes the control's value, so the
                // preview opens on what it decided and the user only touches
                // it to disagree (#643).
                previewMealType = checked.mealType
                phase = .preview(checked)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Where the estimate is actually written.
    ///
    /// The duplicate check runs HERE rather than before the call, because the
    /// meal type it compares on is frequently the model's answer rather than the
    /// user's, and there is nothing to compare before that comes back.
    private func confirm(_ checked: CheckedMealEstimate) {
        // The type the user is looking at, which is the model's answer unless
        // they changed it (#643). Applied to the estimate itself rather than
        // carried alongside it, so the duplicate check, `loggedAt` and the
        // written row all read one value and cannot disagree.
        var decided = checked
        decided.mealType = previewMealType
        checkDuplicates(
            .estimate(decided),
            mealType: decided.mealType,
            description: descriptionToWrite(for: decided)
        )
    }

    /// Hold the intent, look for a meal it repeats, and either write it or ask.
    ///
    /// Both write paths come through here, so the soft duplicate rule cannot
    /// end up applying to one of them and not the other.
    private func checkDuplicates(
        _ pending: PendingWrite,
        mealType: MealType,
        description: String
    ) {
        let candidate = MealDuplicateCandidate(
            id: "pending",
            dayAnchor: WallClock.dayAnchor(from: day),
            mealType: mealType,
            mealDescription: description,
            loggedAt: loggedAt(for: mealType)
        )
        let existing = existingOnDay.map(MealDuplicateCandidate.init)
        let matchedIDs = Set(
            MealDuplicateCheck.matches(for: candidate, among: existing).map(\.id)
        )
        duplicateMatches = existingOnDay.filter { matchedIDs.contains($0.clientUUID) }

        pendingWrite = pending
        if duplicateMatches.isEmpty {
            performWrite()
        } else {
            showingDuplicateChoice = true
        }
    }

    private func resolveDuplicate(_ choice: MealDuplicateChoice) {
        guard pendingWrite != nil else {
            duplicateMatches = []
            return
        }
        switch choice {
        case .keepBoth:
            performWrite()
        case .replace:
            let meals = MealService.default()
            for match in duplicateMatches {
                try? meals.deleteMeal(match)
            }
            performWrite()
        case .discard:
            reset()
        }
        duplicateMatches = []
    }

    private func write(_ checked: CheckedMealEstimate) {
        pendingWrite = .estimate(checked)
        performWrite()
    }

    /// The one write in this view.
    ///
    /// Both paths end here so the two things that must happen on EVERY
    /// successful write — the use counters and the reset — cannot be attached
    /// to one path and forgotten on the other.
    private func performWrite() {
        guard let pending = pendingWrite else { return }
        pendingWrite = nil
        do {
            let meal: LocalMeal
            switch pending {
            case .estimate(let checked):
                meal = try service.save(
                    checked,
                    description: descriptionToWrite(for: checked),
                    day: day,
                    loggedAt: loggedAt(for: checked.mealType),
                    // Empty on path 1, so this is the #543 write unchanged.
                    extraItems: pickedItems
                )
            case .library(let mealType):
                meal = try service.saveFromLibrary(
                    items: pickedItems,
                    mealType: mealType,
                    day: day,
                    loggedAt: loggedAt(for: mealType)
                )
            }
            commitPicks()
            onLogged(meal)
            reset()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Turn the tray into library rows, and count each one as eaten.
    ///
    /// Committing is what makes an item the user's: a hit added from the food
    /// database is written HERE, not when it was tapped, so an item added and
    /// then removed leaves nothing behind and the list stays something that
    /// accumulates by use rather than by curation (#625).
    ///
    /// It runs only once the meal exists, because the counters are a claim
    /// about a meal that was written. The one implementation lives on
    /// `FoodItemPick` so this view and `MealPlanEntrySheet` cannot disagree
    /// about what a commit does.
    private func commitPicks() {
        FoodItemPick.commit(picks, countingUse: true)
    }

    /// Whether there is anything left to log once the estimate has failed.
    ///
    /// The fallback writes the DESCRIPTION with no numbers on it, which is worth
    /// having: the fact that you ate survives, and detail can be added later.
    /// A meal whose only input was a photograph has no description to fall back
    /// on — the photo is not kept (#627) — so the row would carry an empty
    /// string, name nothing, and be impossible to re-estimate. Offering the
    /// button there would be offering an empty row. Try again is the only
    /// honest move, and it still has the photo to try with.
    private var canLogWithoutNumbers: Bool {
        !trimmed.isEmpty || !picks.isEmpty
    }

    /// Save the description with zero nutrients and a needs-detail flag.
    ///
    /// The estimate is what failed, not the meal. Losing the fact that you ate
    /// is worse than losing the number.
    private func logWithoutNumbers() {
        guard canLogWithoutNumbers else { return }
        let fallback = CheckedMealEstimate(
            mealType: libraryMealType,
            items: [],
            nutrients: .zero,
            confidence: 0,
            assumptionsNote: nil,
            // A tray with something in it means the meal is NOT numberless:
            // the picked rows carry their own figures and `save` totals them.
            // Flagging it needs-detail would put "no food identified" on a row
            // that names two packets (#625).
            needsDetail: picks.isEmpty,
            containsAlcohol: false,
            failures: []
        )
        write(fallback)
    }

    private func reset() {
        descriptionText = ""
        typeOverride = nil
        phase = .idle
        duplicateMatches = []
        pendingWrite = nil
        // The tray is composer state like the field is, so it clears with it.
        // Leaving it behind would put the last meal's yogurt into the next one.
        picks = []
        // Same rule, same reason: a photograph left attached would be sent with
        // the NEXT meal, and a stale plate is a worse input than no plate.
        photos = []
        captureNotice = nil
    }

    /// The instant to stamp on the meal, and the ONLY place the composer decides
    /// it (#592).
    ///
    /// Today logs at the real clock. An earlier day logs at the hour that type
    /// of meal is eaten, because "now" on a day that has ended is not a time
    /// anyone ate, and the midday stamp this replaces printed "12:00" on a
    /// dinner logged three days late.
    ///
    /// The type is only known once the estimate comes back, which is why this
    /// takes it as a parameter and why nothing calls it before then.
    /// `confirm(_:)` measures the two-hour duplicate window from this same call,
    /// so the instant the check reads and the instant written onto the row are
    /// derived the same way and cannot drift apart.
    private func loggedAt(for type: MealType) -> Date {
        if isToday { return Date() }
        return MealEstimationService.retrospectiveInstant(for: type, on: day)
    }

    /// The instant the estimate call infers a meal type from when the user
    /// picked none.
    ///
    /// NOT the instant that gets written. Nothing knows the meal type yet at
    /// that point, so an earlier day has nothing better to offer than its own
    /// middle; `loggedAt(for:)` then stamps the row from the type that came
    /// back.
    private func estimateReferenceInstant() -> Date {
        let calendar = Calendar.current
        if isToday { return Date() }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    /// Weekday and short date, matching the `d MMM` the section chrome uses.
    private static let dayPhraseFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMM"
        return f
    }()

    private var duplicateTitle: String {
        duplicateMatches.count == 1
            ? "This looks like a meal you already logged"
            : "This looks like meals you already logged"
    }
}

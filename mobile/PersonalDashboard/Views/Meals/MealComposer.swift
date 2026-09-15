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
/// ### Why the preview is not optional
///
/// The estimate is a guess about portions, and the assumptions it made are the
/// only part of it a user can argue with. Writing straight to the log would mean
/// the first time anyone saw "assumed 10 g of butter" was after the day's totals
/// had already moved.
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
    /// Whether the meal-type options are open. They float in a popover over
    /// the composer rather than growing inside it, so opening the picker never
    /// moves the description field or the Estimate button.
    @State private var typePickerOpen = false
    #if os(macOS)
    @State private var triggerHovering = false
    #endif
    @State private var phase: MealComposerPhase = .idle

    /// Meals the pending estimate duplicates. Non-empty puts the choice in
    /// front of the user; it never blocks the write.
    @State private var duplicateMatches: [LocalMeal] = []
    @State private var showingDuplicateChoice = false

    @FocusState private var fieldFocused: Bool

    /// Writes go through the shared store, the same one every other surface
    /// uses. This view holds no `@Query` of its own: `MealsView` owns the day's
    /// rows and hands them down, so there is exactly one place that decides
    /// which day is on screen.
    private var service: MealEstimationService { .default() }

    private var trimmed: String {
        descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canEstimate: Bool {
        !trimmed.isEmpty && phase != .estimating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("What did you eat?").eyebrow()

            field

            // Centred: the options open in a popover now, so this row never
            // changes height and the two controls can sit as a matched pair.
            HStack(alignment: .center, spacing: Space.sm) {
                typeDropdown
                    .frame(maxWidth: 240)
                Spacer(minLength: Space.sm)
                estimateButton
            }

            switch phase {
            case .idle:
                EmptyView()
            case .estimating:
                estimatingRow
            case .preview(let checked):
                MealEstimatePreview(
                    checked: checked,
                    description: trimmed,
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

    private var field: some View {
        TextField(
            PlainFieldPlaceholder.title(Self.placeholderExample),
            text: $descriptionText,
            axis: .vertical
        )
        .font(.edBody)
        .foregroundStyle(Tokens.ink)
        .lineLimit(2...5)
        .textFieldStyle(.plain)
        .focused($fieldFocused)
        .padding(Space.md)
        .plainFieldPlaceholder(
            Self.placeholderExample,
            isVisible: descriptionText.isEmpty,
            padding: Space.md
        )
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .stroke(Tokens.border, lineWidth: 0.5)
        )
        .accessibilityLabel("Describe the meal")
        .onSubmit { if canEstimate { estimate() } }
    }

    /// Meal type, or "let Dexter decide".
    ///
    /// Not a `Menu` (#540). A system menu panel is the one control the design
    /// system cannot reach: system font, system row metrics, system checkmarks,
    /// and a different panel again on macOS. The rows here are the same
    /// `InlineDropdownRow`s Finance uses, so the open state is still drawn out
    /// of the design system.
    ///
    /// It no longer opens *inside* the form either. Growing the list in place
    /// pushed the description field, the Estimate button and everything below
    /// them down the screen every time the picker opened, for a choice most
    /// meals never make. A popover floats the rows over the surface and leaves
    /// the composer exactly where it was.
    private var typeDropdown: some View {
        Button {
            typePickerOpen.toggle()
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: typeOverride?.sfSymbol ?? "wand.and.stars")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(typeOverride == nil ? Tokens.muted : Tokens.accentMeals)
                    .frame(width: 24, alignment: .leading)
                Text(typeOverride?.displayName ?? "Auto")
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                Spacer(minLength: Space.sm)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Tokens.muted)
                    .rotationEffect(.degrees(typePickerOpen ? 180 : 0))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The metrics `EdButtonStyle` applies at `size: .sm`, which is what
            // the Estimate button beside this one uses: 12 horizontal, 6
            // vertical (Design/Buttons.swift, `hpad` / `vpad`). `InlineDropdown`
            // pads `Space.md` (12) all round, which made this trigger read half
            // again as tall as the button it sits next to.
            .padding(.horizontal, Space.md)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(triggerBackground, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(triggerBorder, radius: Radius.md)
        #if os(macOS)
        // Stripping the system chrome takes the button's own highlight with it,
        // and without a hover response a bordered surface reads as a static
        // caption rather than something you can open. The same rule
        // `InlineDropdown` follows, so this picker and the Finance one behave
        // alike under the pointer.
        .onHover { triggerHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: triggerHovering)
        #endif
        .popover(isPresented: $typePickerOpen, arrowEdge: .bottom) {
            typeOptions
        }
        .accessibilityLabel("Meal type, \(typeOverride?.displayName ?? "decided automatically")")
    }

    private var triggerBackground: Color {
        #if os(macOS)
        return triggerHovering && !typePickerOpen ? Tokens.surface2 : Tokens.surface
        #else
        return Tokens.surface
        #endif
    }

    private var triggerBorder: Color {
        #if os(macOS)
        return triggerHovering || typePickerOpen ? Tokens.borderStrong : Tokens.border
        #else
        return typePickerOpen ? Tokens.borderStrong : Tokens.border
        #endif
    }

    /// The five options, floated over the composer.
    ///
    /// Fixed to the trigger's own 240pt so the panel and the control it came
    /// from are one width, and the labels keep the 24pt glyph slot they line up
    /// against in the closed state.
    private var typeOptions: some View {
        VStack(spacing: 0) {
            InlineDropdownRow(
                glyph: .symbol("wand.and.stars"),
                label: "Let Dexter decide",
                isSelected: typeOverride == nil,
                accent: Tokens.accentMeals
            ) { selectType(nil) }

            InlineDropdownDivider()

            ForEach(MealType.allCases) { type in
                InlineDropdownRow(
                    glyph: .symbol(type.sfSymbol),
                    label: type.displayName,
                    isSelected: typeOverride == type,
                    accent: Tokens.accentMeals
                ) { selectType(type) }
            }
        }
        .padding(.vertical, Space.xs)
        .frame(width: 240)
        .background(Tokens.surface)
        // The panel's chrome belongs to the system; this puts it back on the
        // design system's surface colour in both themes.
        .presentationBackground(Tokens.surface)
        // Without this an iPhone adapts a popover into a full-screen sheet,
        // which is a far bigger interruption than the inline list this
        // replaces. Available from iOS 16.4 / macOS 13.3, both below the 17.0 /
        // 14.0 deployment targets in project.yml, so no availability guard.
        .presentationCompactAdaptation(.popover)
    }

    private func selectType(_ type: MealType?) {
        typeOverride = type
        typePickerOpen = false
    }

    private var estimateButton: some View {
        Button {
            estimate()
        } label: {
            Text(phase == .estimating ? "Estimating…" : "Estimate")
        }
        .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
        .disabled(!canEstimate)
        .opacity(canEstimate ? 1 : 0.5)
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
                Button("Log it without numbers") { logWithoutNumbers() }
                    .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
            }
        }
    }

    // MARK: - Actions

    private func estimate() {
        guard canEstimate else { return }
        let description = trimmed
        let hint = typeOverride
        let at = loggedAt()
        fieldFocused = false
        phase = .estimating
        Task {
            do {
                let checked = try await service.estimate(
                    description: description,
                    mealTypeHint: hint,
                    loggedAt: at
                )
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
        let candidate = MealDuplicateCandidate(
            id: "pending",
            dayAnchor: WallClock.dayAnchor(from: day),
            mealType: checked.mealType,
            mealDescription: trimmed,
            loggedAt: loggedAt()
        )
        let existing = existingOnDay.map(MealDuplicateCandidate.init)
        let matchedIDs = Set(
            MealDuplicateCheck.matches(for: candidate, among: existing).map(\.id)
        )
        duplicateMatches = existingOnDay.filter { matchedIDs.contains($0.clientUUID) }

        if duplicateMatches.isEmpty {
            write(checked)
        } else {
            showingDuplicateChoice = true
        }
    }

    private func resolveDuplicate(_ choice: MealDuplicateChoice) {
        guard case .preview(let checked) = phase else {
            duplicateMatches = []
            return
        }
        switch choice {
        case .keepBoth:
            write(checked)
        case .replace:
            let meals = MealService.default()
            for match in duplicateMatches {
                try? meals.deleteMeal(match)
            }
            write(checked)
        case .discard:
            reset()
        }
        duplicateMatches = []
    }

    private func write(_ checked: CheckedMealEstimate) {
        do {
            let meal = try service.save(
                checked,
                description: trimmed,
                day: day,
                loggedAt: loggedAt()
            )
            onLogged(meal)
            reset()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Save the description with zero nutrients and a needs-detail flag.
    ///
    /// The estimate is what failed, not the meal. Losing the fact that you ate
    /// is worse than losing the number.
    private func logWithoutNumbers() {
        let fallback = CheckedMealEstimate(
            mealType: typeOverride ?? MealEstimationService.inferredType(at: loggedAt()),
            items: [],
            nutrients: .zero,
            confidence: 0,
            assumptionsNote: nil,
            needsDetail: true,
            containsAlcohol: false,
            failures: []
        )
        write(fallback)
    }

    private func reset() {
        descriptionText = ""
        typeOverride = nil
        typePickerOpen = false
        phase = .idle
        duplicateMatches = []
    }

    /// The instant to stamp on the meal.
    ///
    /// Today logs at the real clock. A past day logs at midday on that day,
    /// because "now" on a day that has ended is not a time anyone ate, and the
    /// two-hour duplicate window needs an instant that sits inside the day it
    /// belongs to.
    private func loggedAt() -> Date {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return Date() }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    private var duplicateTitle: String {
        duplicateMatches.count == 1
            ? "This looks like a meal you already logged"
            : "This looks like meals you already logged"
    }
}

import SwiftUI
import SwiftData

/// What the targets sheet is doing right now (#544).
enum MealTargetsPhase: Equatable {
    /// Filling the form, or reviewing an answer. Both are the same state: the
    /// fields are editable in either, and the only difference is whether there
    /// is anything in the eight yet.
    case editing
    case deriving
    case failed(String)
}

/// Derive, review and save the eight daily targets (#544).
///
/// ### The order of the screen is the order of the decision
///
/// Six inputs, then one button, then eight editable figures and the paragraph
/// explaining them, then Save. Nothing is written until that last step —
/// deriving is a question, not a commitment, and a screen that stored on the
/// way past would make "what would it say if I were 5 kg lighter" a destructive
/// thing to ask.
///
/// ### One API call
///
/// Deriving is a one-time cost. There is no call on appear, no call to validate
/// a field, and no second call to check the first. Everything after the answer
/// lands is local editing.
///
/// ### Hand-edited figures
///
/// A figure the user changes is saved flagged, so a later re-derivation can
/// show what it would have suggested without overwriting a deliberate choice.
/// The flag is computed by `MealTargetDraft`, never set by this view — a view
/// that remembered it would forget it on the one path nobody tested.
struct MealTargetsSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// v1 holds one record. Queried rather than passed so the sheet always
    /// opens on the live row, from Meals and from Settings alike.
    @Query(sort: [SortDescriptor(\MealTargets.effectiveFrom, order: .forward)])
    private var allTargets: [MealTargets]

    @State private var inputs = MealTargetInputs()
    @State private var draft = MealTargetDraft(stored: nil)
    @State private var phase: MealTargetsPhase = .editing

    /// The three numeric inputs and the eight figures are held as the text the
    /// user typed, not as parsed numbers. Re-formatting a field mid-keystroke
    /// is how "1." becomes "1" under the cursor.
    @State private var ageText = ""
    @State private var heightText = ""
    @State private var weightText = ""
    @State private var targetText: [Nutrient: String] = [:]

    @State private var loaded = false
    @State private var saveError: String?

    private var client: AnthropicClient { AnthropicClient() }
    private var service: MealService { .default() }

    /// The record in force, by the same rule `MealService.targets(on:)` uses.
    private var existing: MealTargets? {
        let anchor = WallClock.dayAnchor(from: Date())
        return allTargets.last { WallClock.startOfStoredDay($0.effectiveFrom) <= anchor }
            ?? allTargets.first
    }

    private var isDeriving: Bool { phase == .deriving }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.canvasIgnoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.lg) {
                            if existing == nil {
                                intro
                            }
                            aboutYouSection
                            deriveSection
                            if draft.isReviewable {
                                reviewSection
                            }
                            if let saveError {
                                Text(saveError)
                                    .font(.edFootnote)
                                    .foregroundStyle(Tokens.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(Space.lg)
                    }

                    footer
                }
            }
            .navigationTitle("Daily targets")
            .inlineNavigationTitle()
        }
        #if os(macOS)
        // A macOS sheet with no explicit size collapses to its toolbar (#474).
        // On a phone this minWidth is wider than the screen, so it stays out of
        // the iOS tree entirely.
        .frame(minWidth: 520, idealWidth: 560, minHeight: 620, idealHeight: 760)
        #endif
        .onAppear(perform: load)
    }

    // MARK: - Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Why these six").eyebrow()
            Text("Resting energy is worked out from age, sex, height and weight, then scaled by how much you move and adjusted for what you are after. Sex is in the list because the equation carries a different constant for each, worth about 160 kcal a day on the same body.")
                .font(.edSubheadline)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The six

    private var aboutYouSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("About you").eyebrow()

            VStack(alignment: .leading, spacing: Space.xs) {
                MealNumberField(
                    label: "Age",
                    unit: "yrs",
                    text: Binding(
                        get: { ageText },
                        set: { ageText = $0; inputs.ageYears = Int(MealItemDraft.number($0).rounded()) }
                    )
                )

                MealTargetsChoiceField(
                    label: "Biological sex",
                    options: BiologicalSex.allCases,
                    title: \.displayName,
                    selection: $inputs.biologicalSex
                )

                MealNumberField(
                    label: "Height",
                    unit: "cm",
                    text: Binding(
                        get: { heightText },
                        set: { heightText = $0; inputs.heightCm = MealItemDraft.number($0) }
                    )
                )

                MealNumberField(
                    label: "Weight",
                    unit: "kg",
                    text: Binding(
                        get: { weightText },
                        set: { weightText = $0; inputs.weightKg = MealItemDraft.number($0) }
                    )
                )

                MealTargetsChoiceField(
                    label: "Activity",
                    options: ActivityLevel.allCases,
                    title: \.displayName,
                    selection: $inputs.activityLevel
                )

                // The band's own definition, under the field rather than inside
                // the option rows: `InlineDropdownRow` draws one line, and a
                // second control shape for one dropdown would break the pattern
                // Finance and the composer already share.
                Text(inputs.activityLevel.detail)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                MealTargetsChoiceField(
                    label: "Goal",
                    options: MealGoal.allCases,
                    title: \.displayName,
                    selection: $inputs.goal
                )
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    // MARK: - Derive

    private var deriveSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Button(isDeriving ? "Working it out…" : deriveTitle) { derive() }
                    .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                    .disabled(isDeriving || !inputs.isComplete)
                    .opacity(isDeriving || !inputs.isComplete ? 0.5 : 1)

                if isDeriving {
                    ProgressView()
                        #if os(macOS)
                        .controlSize(.small)
                        #else
                        .scaleEffect(0.7)
                        #endif
                }

                Spacer(minLength: Space.sm)
            }

            if case .failed(let message) = phase {
                Text(message)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let problem = inputs.problem {
                Text(problem)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !draft.isReviewable {
                Text("One request to Claude. The eight numbers come back editable and nothing is stored until you save.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var deriveTitle: String {
        draft.isReviewable ? "Derive again" : "Derive targets"
    }

    // MARK: - Review

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Your targets").eyebrow()

            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Nutrient.allCases) { nutrient in
                    VStack(alignment: .leading, spacing: 2) {
                        MealNumberField(
                            label: nutrient.displayName,
                            unit: nutrient.unit,
                            text: Binding(
                                get: { targetText[nutrient] ?? "0" },
                                set: {
                                    targetText[nutrient] = $0
                                    draft.set(MealItemDraft.number($0), for: nutrient)
                                }
                            )
                        )
                        // Stated in words, not in a hue: on this surface colour
                        // is a verdict about a day, and a changed target is not
                        // a verdict about anything.
                        if let suggestion = draft.overriddenSuggestion(for: nutrient) {
                            Text("You changed this. Derived \(MealFormat.value(suggestion, for: nutrient)).")
                                .font(.edCaption)
                                .foregroundStyle(Tokens.muted)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)

            if !draft.rationale.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("How these were worked out").eyebrow()
                    Text(draft.rationale)
                        .font(.edSubheadline)
                        .foregroundStyle(Tokens.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.md)
            }

            Text("Past days are read against whichever targets are current. Changing these changes how earlier days look.")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    /// The secondary action sits immediately to the left of the primary, not
    /// marooned at the other end of the bar.
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Tokens.divider)
                .frame(height: 0.5)

            HStack(spacing: Space.sm) {
                Spacer(minLength: Space.sm)
                Button("Cancel") { dismiss() }
                    .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                Button("Save") { save() }
                    .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                    .disabled(!draft.hasAnyTarget || isDeriving)
                    .opacity(!draft.hasAnyTarget || isDeriving ? 0.5 : 1)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
        }
        .background(Tokens.surface)
    }

    // MARK: - Actions

    /// Pre-fill every field from the record in force, so re-deriving after a
    /// weight change is one number and one tap.
    private func load() {
        guard !loaded else { return }
        loaded = true

        let stored = existing
        if let stored {
            inputs = MealTargetInputs(stored: stored)
            ageText = stored.ageYears > 0 ? "\(stored.ageYears)" : ""
            heightText = stored.heightCm > 0 ? MealItemDraft.string(stored.heightCm) : ""
            weightText = stored.weightKg > 0 ? MealItemDraft.string(stored.weightKg) : ""
        }
        draft = MealTargetDraft(stored: stored)
        syncTargetText()
    }

    private func derive() {
        guard !isDeriving else { return }
        let request = inputs
        phase = .deriving
        saveError = nil
        Task {
            do {
                let derived = try await client.deriveMealTargets(inputs: request)
                draft.apply(derived)
                syncTargetText()
                phase = .editing
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func save() {
        guard draft.hasAnyTarget else { return }
        do {
            try service.saveTargets(
                targets: draft.values,
                ageYears: inputs.ageYears,
                biologicalSex: inputs.biologicalSex.rawValue,
                heightCm: inputs.heightCm,
                weightKg: inputs.weightKg,
                activityLevel: inputs.activityLevel.rawValue,
                goal: inputs.goal.rawValue,
                rationale: draft.rationale,
                // Keep the day the record has always applied from. v1 is not
                // versioned, so moving it forward would leave every earlier day
                // reading against the fallback rather than against these.
                effectiveFrom: existing?.deviceEffectiveFrom ?? Date(),
                handEdited: draft.handEdited,
                clientUUID: existing?.clientUUID
            )
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Re-render the eight text fields from the draft. Called only after the
    /// draft changes underneath them — never while the user is typing, which
    /// would rewrite the field under the cursor.
    private func syncTargetText() {
        for nutrient in Nutrient.allCases {
            targetText[nutrient] = MealItemDraft.string(draft.values[nutrient])
        }
    }
}

/// One of a handful of choices, drawn out of the design system (#544).
///
/// Not a `Menu` (#540): a system menu panel is the one control the design
/// system cannot reach. The rows are the same `InlineDropdownRow`s Finance and
/// the meal composer use, floated in a popover so opening the list never moves
/// the fields under it.
struct MealTargetsChoiceField<Option: Identifiable & Hashable>: View {
    let label: String
    let options: [Option]
    let title: KeyPath<Option, String>
    @Binding var selection: Option

    @State private var open = false
    #if os(macOS)
    @State private var hovering = false
    #endif

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(label)
                .font(.edFootnote)
                .foregroundStyle(Tokens.inkSoft)
            Spacer(minLength: Space.sm)
            trigger
                .frame(width: 180)
        }
        .padding(.vertical, 2)
    }

    private var trigger: some View {
        Button { open.toggle() } label: {
            HStack(spacing: Space.sm) {
                Text(selection[keyPath: title])
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                Spacer(minLength: Space.xs)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Tokens.muted)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(background, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .paperBorder(border, radius: Radius.sm)
        #if os(macOS)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        #endif
        .popover(isPresented: $open, arrowEdge: .bottom) { panel }
        .accessibilityLabel("\(label), \(selection[keyPath: title])")
    }

    private var panel: some View {
        VStack(spacing: 0) {
            ForEach(options) { option in
                InlineDropdownRow(
                    glyph: .none,
                    label: option[keyPath: title],
                    isSelected: option == selection,
                    accent: Tokens.accentMeals
                ) {
                    selection = option
                    open = false
                }
            }
        }
        .padding(.vertical, Space.xs)
        .frame(width: 240)
        .background(Tokens.surface)
        .presentationBackground(Tokens.surface)
        // Without this an iPhone adapts a popover into a full-screen sheet.
        // Available from iOS 16.4 / macOS 13.3, both below the deployment
        // targets in project.yml, so no availability guard.
        .presentationCompactAdaptation(.popover)
    }

    private var background: Color {
        #if os(macOS)
        return hovering && !open ? Tokens.surface2 : Tokens.surface
        #else
        return Tokens.surface
        #endif
    }

    private var border: Color {
        #if os(macOS)
        return hovering || open ? Tokens.borderStrong : Tokens.border
        #else
        return open ? Tokens.borderStrong : Tokens.border
        #endif
    }
}

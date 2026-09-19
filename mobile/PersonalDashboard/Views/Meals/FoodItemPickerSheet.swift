import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

/// Find an item and add it to the meal (#625).
///
/// ### Why this sheet exists beside the composer
///
/// The composer takes a sentence and returns an estimate, which is the right
/// bargain for "chicken rice and a teh tarik": nobody knows those numbers and a
/// model's guess beats a blank. It is the wrong bargain for a packet. The back
/// of a Farmers Union pot states its numbers exactly, and re-estimating it costs
/// a call, a few seconds, and a slightly different answer every time, so two
/// logs of one pot disagree and a week's protein is the sum of the disagreement.
///
/// So there are exactly two ways to log a meal: describe it in text, or find it
/// here. Nothing in this sheet estimates anything.
///
/// ### One field, one list, two sources
///
/// Typing searches the user's own items instantly and out of the store, and it
/// searches the public food database in the background. Both answers land in one
/// list: his items first, then hits that are not his yet, under a quiet label
/// each. The label is there because the two rows behave differently once tapped
/// — one of his is editable, archivable and ranked, a database row is a
/// stranger's record — but the list has to read as one result set, because "is
/// this thing in my list or in theirs" is not a question anyone wants to answer
/// before eating.
///
/// A hit matching one of his rows on `externalID` or `barcode` is dropped in
/// favour of the row, because his copy may carry corrections. See
/// `FoodItemSearchMerge`.
///
/// ### Why the public database is a behaviour and not a button
///
/// It used to be a button, on the theory that Open Food Facts is crowd-sourced
/// and a hit is a proposal rather than a fact. That theory was right and the
/// design built on it was wrong: it made the list something the user had to
/// curate, by hand or by pressing a second control, and the reason to keep a
/// library at all is to stop describing the same wafer every morning.
///
/// The crowd-sourcing is now answered where it costs nothing. Every row prints
/// its calories and its protein BEFORE the tap, a record with figures missing
/// says how many, and every item stays editable afterwards. `isVerified` stays
/// false on anything that arrived this way, so the list can still say which rows
/// nobody has read against a packet.
///
/// The network is respected by the debounce and the cancellation rather than by
/// a button: one request leaves per pause in typing, the one before it is
/// cancelled, and a query under two characters never leaves at all. A failure is
/// a quiet line under the user's own matches, never a blank list.
///
/// ### Why one tap adds, and a second tap removes
///
/// A row goes in at its usual serving, which for one of his is the 150 g pot he
/// told the library about and for a hit is whatever its record states. The
/// common case is find, tap, Done, with nothing typed. Tapping a row already in
/// the tray takes it out again, so a mis-tap costs one tap.
///
/// Nothing is written to the library here, not even by a tap on a database hit.
/// `FoodItemPick.commit` runs when the meal is written, which is what keeps a
/// hit the user tried and removed out of a list he never asked to maintain.
///
/// Editing is NEVER a long press. The per-row menu behind the trailing glyph is
/// the one way to reach Edit, Archive and Delete, and the same menu answers a
/// right-click on the Mac. A tap means add, everywhere, with no second meaning.
struct FoodItemPickerSheet: View {

    /// The tray as it already stands, for a caller re-opening the sheet on a
    /// meal it has not committed yet.
    let initialPicks: [FoodItemPick]

    /// The WHOLE tray, not a delta. A caller replaces what it held rather than
    /// merging, which is what makes Cancel mean "nothing happened" without the
    /// sheet having to track what it removed.
    let onDone: ([FoodItemPick]) -> Void

    init(initialPicks: [FoodItemPick] = [], onDone: @escaping ([FoodItemPick]) -> Void) {
        self.initialPicks = initialPicks
        self.onDone = onDone
    }

    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""

    /// The user's own rows answering the current query, in the service's order.
    @State private var matches: [LocalFoodItem] = []

    /// Every row in the store, archived ones included, keyed by `clientUUID`.
    ///
    /// The tray reads this to rescale a `.saved` pick, and it has to include
    /// archived rows: an item retired after it was picked must still be able to
    /// answer "what are 200 g of you", or the amount field on a pick already
    /// made would go dead.
    @State private var rowsByUUID: [String: LocalFoodItem] = [:]

    /// True when the store holds nothing at all, which is a different state
    /// from "nothing answers what you typed" and gets a different sentence.
    @State private var libraryIsEmpty = false

    @State private var picks: [FoodItemPick] = []

    /// The amount each pick is being edited at, as text.
    ///
    /// Text rather than a `Double` for the reason `MealNumberField` exists: a
    /// half-typed "1." is not a number, and a formatted binding rewrites the
    /// field under the caret when it cannot parse one.
    @State private var amounts: [UUID: String] = [:]

    @State private var remote: RemotePhase = .idle

    /// The database's answer to the last query that finished, before dedupe.
    ///
    /// Raw rather than merged, so deleting one of his rows while the sheet is
    /// open puts the hit it was hiding back on screen.
    @State private var remoteHits: [FoodItemDraft] = []

    /// The debounce and the request, as one cancellable unit. Cancelling it
    /// mid-sleep is what keeps a five-letter query down to one call.
    @State private var searchTask: Task<Void, Never>?

    @State private var editorTarget: FoodItemEditorTarget?

    @State private var errorMessage: String?

    /// What the last scan came to, when it came to something worth saying.
    @State private var scanNote: ScanNote?

    @State private var pendingDelete: LocalFoodItem?
    @State private var confirmingDelete = false

    #if os(iOS)
    @State private var showingCamera = false
    @State private var scanning = false
    #endif

    private var items: FoodItemService { .default() }
    private var database: OpenFoodFactsClient { OpenFoodFactsClient() }

    /// How long typing has to stop before a request leaves.
    ///
    /// 350 ms is about the gap between words rather than between letters, so a
    /// whole phrase typed at speed costs one call. Open Food Facts is free and
    /// unkeyed, so the cost being managed here is their rate limiting and the
    /// user's latency, not a bill.
    private static let debounceNanoseconds: UInt64 = 350_000_000

    /// Below this, the database is not asked at all. One letter matches most of
    /// four million products and answers with none of the right ones.
    private static let minimumRemoteQueryLength = 2

    /// Where the public search has got to.
    ///
    /// Cancellation is deliberately NOT a case. A search the user typed over is
    /// not a thing that went wrong, and giving it an error case would mean every
    /// reader had to filter the enum before it could show it.
    private enum RemotePhase: Equatable {
        case idle
        case searching
        /// Answered, for this exact query. Held so a stale empty result does not
        /// claim to be the answer to something newly typed.
        case answered(String)
        case failed(String)
    }

    /// What a barcode scan came to, in the outcomes worth a sentence.
    private enum ScanNote: Identifiable, Equatable {
        /// The photo held no code this device could read.
        case unreadable
        /// The code resolved and the item went straight into the tray. The name
        /// is stated so it is obvious what was added.
        case added(String)
        /// The code read fine and the database has never heard of it.
        case unknown
        /// The code read fine and the database could not be reached.
        case unreachable(String)

        var id: String {
            switch self {
            case .unreadable:           return "unreadable"
            case .added(let name):      return "added-\(name)"
            case .unknown:              return "unknown"
            case .unreachable(let m):   return "unreachable-\(m)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.canvasIgnoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        searchField
                        if let scanNote { scanNoteBlock(scanNote) }
                        if let errorMessage { errorBlock(errorMessage) }
                        resultsSection
                        traySection
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle("Find an item")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                // One `ToolbarItem` renders ONE control: a second item in the
                // same placement replaces the first rather than sitting beside
                // it (#524). Both trailing buttons therefore share one item.
                ToolbarItem(placement: .trailingBar) {
                    HStack(spacing: Space.sm) {
                        #if os(iOS)
                        if cameraAvailable {
                            Button {
                                showingCamera = true
                            } label: {
                                Image(systemName: "barcode.viewfinder")
                            }
                            .accessibilityLabel("Scan a barcode")
                            .disabled(scanning)
                        }
                        #endif
                        Button("Done") { commit() }
                    }
                }
            }
        }
        #if os(macOS)
        // A macOS sheet with no explicit size collapses to its toolbar (#474).
        // On a phone this minWidth is wider than the screen, so it stays out of
        // the iOS tree entirely.
        .frame(minWidth: 540, idealWidth: 620, minHeight: 620, idealHeight: 780)
        #endif
        .onAppear(perform: load)
        .onChange(of: query) { _, _ in
            queryChanged()
        }
        .onDisappear {
            searchTask?.cancel()
        }
        .sheet(item: $editorTarget) { target in
            FoodItemEditorSheet(target: target) { _ in
                editorTarget = nil
                adoptEdit()
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            // UIKit's camera is itself full screen and fights a sheet's detents,
            // which is why Finance presents it this way too.
            CameraPicker { data in
                showingCamera = false
                handleCapture(data)
            }
            .ignoresSafeArea()
        }
        #endif
        .confirmationDialog(
            pendingDelete.map { "Delete \($0.displayName)?" } ?? "Delete this item?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteConfirmed() }
            Button("Keep it", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Meals you already logged from it keep their own numbers and are untouched.")
        }
    }

    // MARK: - Search

    private static let searchExample = "Search your items and the food database"

    private var searchField: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Tokens.muted)
            TextField(PlainFieldPlaceholder.title(Self.searchExample), text: $query)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .textFieldStyle(.plain)
                .paperFieldOnMac()
                .autocorrectionDisabled(true)
                .noAutocapitalization()
                .plainFieldPlaceholder(Self.searchExample, isVisible: query.isEmpty, padding: 0)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Tokens.mutedSoft)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every keystroke: answer locally at once, and reschedule the network.
    ///
    /// The local half must never wait on the remote half, which is the reason
    /// these are two statements rather than one async pass. His own items are in
    /// the store on this device and answer in microseconds; the database is
    /// somebody else's server.
    private func queryChanged() {
        reloadMatches()
        scheduleRemoteSearch()
    }

    /// Cancel what is in flight, then start the debounce.
    ///
    /// The sleep is INSIDE the task, so cancelling on the next keystroke kills
    /// a pending request before it is sent as readily as one already sent. The
    /// phase only moves to `.searching` after the sleep, so a query that gets
    /// typed over never shows a spinner for a call that never left.
    ///
    /// The previous hits are cleared immediately: they answer a query the user
    /// has moved off, and leaving them under the new text would be the list
    /// telling a small lie while it waits.
    private func scheduleRemoteSearch() {
        searchTask?.cancel()
        searchTask = nil
        remoteHits = []

        let term = trimmedQuery
        guard term.count >= Self.minimumRemoteQueryLength else {
            remote = .idle
            return
        }

        remote = .idle
        searchTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                try Task.checkCancellation()
                remote = .searching
                let hits = try await database.search(term)
                try Task.checkCancellation()
                remoteHits = hits.map(\.draft)
                remote = .answered(term)
            } catch is CancellationError {
                // The user typed on. Nothing to report and nothing to reset:
                // whoever cancelled us has already set the next phase.
            } catch {
                remote = .failed(error.localizedDescription)
            }
        }
    }

    /// Run the search again after a failure, from the same field.
    private func retryRemoteSearch() {
        scheduleRemoteSearch()
    }

    // MARK: - The one result list

    /// The database hits worth showing, with anything he already has removed.
    ///
    /// Computed rather than stored so it re-derives when his own rows change:
    /// deleting a row puts the hit it was hiding straight back.
    private var databaseHits: [FoodItemDraft] {
        FoodItemSearchMerge.databaseHits(remoteHits, excluding: matches)
    }

    private var hasAnyResult: Bool {
        !matches.isEmpty || !databaseHits.isEmpty
    }

    /// The results and whatever the network has to say about itself, under one
    /// root.
    ///
    /// One container rather than loose statements: a multi-statement
    /// `@ViewBuilder` flattens into its parent, and anything later attached to
    /// this property would then be applied to each child separately (#597).
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if hasAnyResult {
                resultList
            } else if remote != .searching {
                noResultsBlock
            }
            remoteStatus
        }
    }

    /// His items and the database's, in one card.
    ///
    /// One surface with labelled groups inside it rather than two cards,
    /// because it is one answer to one question. The labels say which rows are
    /// his, since only those can be edited, archived or deleted.
    private var resultList: some View {
        VStack(spacing: 0) {
            if !matches.isEmpty {
                groupHeader("Your items")
                ForEach(matches, id: \.clientUUID) { item in
                    libraryRow(item)
                    if item.clientUUID != matches.last?.clientUUID { rowDivider }
                }
            }
            if !databaseHits.isEmpty {
                if !matches.isEmpty { rowDivider }
                groupHeader("From the food database")
                ForEach(Array(databaseHits.enumerated()), id: \.offset) { pair in
                    databaseRow(pair.element)
                    if pair.offset != databaseHits.count - 1 { rowDivider }
                }
            }
        }
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .eyebrow()
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
            .padding(.bottom, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Tokens.divider)
            .frame(height: 0.5)
    }

    /// One saved item: the name, what a usual serving of it costs, and the menu.
    ///
    /// The tick is on the leading edge rather than the trailing one because the
    /// trailing edge already belongs to the menu, and a checkmark beside an
    /// ellipsis reads as one control with two halves.
    private func libraryRow(_ item: LocalFoodItem) -> some View {
        let picked = isPicked(item)
        return HStack(spacing: Space.sm) {
            Button {
                toggle(item)
            } label: {
                HStack(alignment: .top, spacing: Space.md) {
                    pickGlyph(picked)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Space.xs) {
                            Text(item.displayName)
                                .font(.edBody)
                                .foregroundStyle(Tokens.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if !item.isVerified {
                                // A row nobody has read against the packet. The
                                // marker is quiet on purpose: the numbers are
                                // probably right, and the user is the only one
                                // who can say so.
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundStyle(Tokens.warning)
                                    .accessibilityHidden(true)
                            }
                        }
                        Text(servingLine(item))
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                            .monospacedDigit()
                    }

                    Spacer(minLength: 0)
                }
                // A `Button` wrapping bare text has no fill of its own, so
                // without this only the glyphs answer a tap (#530).
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.displayName)
            .accessibilityValue(picked ? "In the meal" : "Not in the meal")
            .accessibilityHint(picked ? "Removes it from the meal" : "Adds one usual serving to the meal")

            rowMenu(item)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        // Right-clicking the row reaches the same three actions on the Mac.
        .contextMenu { rowActions(item) }
    }

    private func pickGlyph(_ picked: Bool) -> some View {
        Image(systemName: picked ? "checkmark.circle.fill" : "plus.circle")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(picked ? Tokens.accentMeals : Tokens.mutedSoft)
            .frame(width: 22, height: 22)
    }

    /// The usual serving and what it costs: "150 g · 148 kcal · 15 g protein".
    ///
    /// Stated precision, not estimate precision. These numbers came off a packet
    /// rather than out of a portion guess, and rounding 148 to 150 would destroy
    /// the one property that makes the library worth keeping (#594).
    private func servingLine(_ item: LocalFoodItem) -> String {
        Self.servingLine(
            quantity: item.defaultPortionQuantity,
            unit: item.unit.rawValue,
            nutrients: item.defaultNutrients
        )
    }

    /// The shared shape of both kinds of row, so his item and a hit state their
    /// serving the same way and cannot be told apart by their formatting.
    private static func servingLine(
        quantity: Double,
        unit: String,
        nutrients: MealNutrients,
        extra: String? = nil
    ) -> String {
        var parts = [
            "\(MealItemDraft.string(quantity)) \(unit)",
            "\(MealFormat.calories(nutrients.calories, .stated)) kcal",
            "\(MealFormat.grams(nutrients.proteinG)) g protein"
        ]
        if let extra { parts.append(extra) }
        return parts.joined(separator: "  ·  ")
    }

    private func rowMenu(_ item: LocalFoodItem) -> some View {
        Menu {
            rowActions(item)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.mutedSoft)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyleCompat()
        .accessibilityLabel("More actions for \(item.displayName)")
    }

    /// Edit, Archive and Delete, in one builder so the trailing menu and the
    /// right-click menu cannot drift apart.
    ///
    /// These are corrections, not curation. Editing is how a number read wrong
    /// off a crowd-sourced record gets fixed once and stays fixed, which is the
    /// half of the bargain that pays for adding a hit with no confirm step.
    @ViewBuilder
    private func rowActions(_ item: LocalFoodItem) -> some View {
        Button {
            editorTarget = .existing(item)
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        Button {
            archive(item)
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = item
            confirmingDelete = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// One database hit. Tapping it adds it to the meal, exactly as one of his
    /// own rows does.
    ///
    /// No confirm form stands in the way, and the row is what pays for that: it
    /// states the serving, the calories and the protein it is about to add, and
    /// says how many figures the record left out. The item stays editable in
    /// the meal and in the library afterwards.
    private func databaseRow(_ draft: FoodItemDraft) -> some View {
        let picked = isPicked(draft)
        return Button {
            toggle(draft)
        } label: {
            HStack(alignment: .top, spacing: Space.md) {
                pickGlyph(picked)

                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.displayName)
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(draftLine(draft))
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(draft.displayName)
        .accessibilityValue(picked ? "In the meal" : "Not in the meal")
        .accessibilityHint(picked ? "Removes it from the meal" : "Adds one serving to the meal")
    }

    private func draftLine(_ draft: FoodItemDraft) -> String {
        Self.servingLine(
            quantity: draft.defaultPortionQuantity,
            unit: draft.basePortionUnit.rawValue,
            nutrients: draft.nutrients(for: draft.defaultPortionQuantity),
            extra: draft.missingNutrients.isEmpty
                ? nil
                : "\(draft.missingNutrients.count) figures not stated"
        )
    }

    /// Nothing answered, from either source.
    ///
    /// The way out is the OTHER way to log a meal, and it is stated rather than
    /// offered as a button: there is no form to fill in here, and a library the
    /// user has to fill by hand is the thing this sheet stopped being.
    private var noResultsBlock: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(noResultsHeadline)
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Text(noResultsAdvice)
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    private var noResultsHeadline: String {
        if trimmedQuery.isEmpty {
            return libraryIsEmpty
                ? "Search for what you are eating."
                : "Every item you have is archived."
        }
        return "Nothing matches \"\(trimmedQuery)\"."
    }

    private var noResultsAdvice: String {
        if trimmedQuery.isEmpty {
            return libraryIsEmpty
                ? "Anything you log from here is remembered, and works its way up this list the more you eat it."
                : "Type a name to search the food database, or unarchive an item by editing it."
        }
        return "Close this and describe the meal in words instead. Dexter will estimate it, and you can save it to your items from the meal afterwards."
    }

    /// What the network is doing, stated under the results and never instead of
    /// them.
    ///
    /// A failure here is a failure of ONE of the two sources. His own items are
    /// already on screen and stay there, so this is a line and not a screen.
    @ViewBuilder
    private var remoteStatus: some View {
        switch remote {
        case .idle:
            if !trimmedQuery.isEmpty && trimmedQuery.count < Self.minimumRemoteQueryLength {
                Text("Keep typing to search the food database.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }

        case .searching:
            HStack(spacing: Space.sm) {
                ProgressView()
                    #if os(macOS)
                    .controlSize(.small)
                    #else
                    .scaleEffect(0.7)
                    #endif
                Text("Searching the food database.")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
            }
            .accessibilityElement(children: .combine)

        case .answered(let term):
            if databaseHits.isEmpty && !matches.isEmpty {
                Text("The food database has nothing else for \"\(term)\".")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .failed(let message):
            // ── Quiet, and stated ONCE ──────────────────────────────────────
            //
            // `message` is already a whole sentence written for a human
            // ("The food database is not answering right now."), so anything
            // this view adds in front of it says the same thing twice. The
            // first build read "Your own items are listed above. The food
            // database could not be reached. The food database is not
            // answering right now.", which names the database three times to
            // report one fact.
            //
            // Muted rather than `danger`, because nothing the user asked for
            // has failed. Their own items are listed above and are the results
            // they came for; a third party is slow. Red here would teach them
            // to read red as noise, on a surface where a real error still has
            // to land (#625).
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(message)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)

                // Only when there is nothing else on screen. With their own
                // matches listed, the route out is obvious and this would be
                // one more line to read.
                if matches.isEmpty {
                    Text("You can close this and describe the meal instead, and Dexter will estimate it.")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Try again") { retryRemoteSearch() }
                    .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
            }
        }
    }

    // MARK: - Barcode scanning

    #if os(iOS)
    /// Hidden rather than disabled on a device with no camera, exactly as the
    /// Finance menu does it, because the simulator falls back to the photo
    /// library and a "Scan" button that opens an album is a lie.
    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// What a photo of a packet comes to, in five branches that all end
    /// somewhere the user can act.
    ///
    /// 1. Nothing was captured: the user cancelled, and nothing is said.
    /// 2. No code in the frame: a sentence saying so, and the button is still
    ///    there.
    /// 3. A code the library already knows: straight into the tray, named.
    /// 4. A code the database knows: straight into the tray, named. No confirm
    ///    form, for the same reason a tapped search hit has none.
    /// 5. A code nobody knows, or a dead network: a sentence, and the other way
    ///    in. There is no form to fall back to here by design.
    private func handleCapture(_ data: Data?) {
        scanNote = nil
        errorMessage = nil
        guard let data, let image = UIImage(data: data) else { return }

        guard let decoded = BarcodeService.decode(image: image) else {
            scanNote = .unreadable
            return
        }
        let code = decoded.payload

        // A code the library already carries skips the network entirely, which
        // is the whole reason `LocalFoodItem.barcode` is stored.
        if let known = (try? items.item(barcode: code)) ?? nil {
            add(known)
            scanNote = .added(known.displayName)
            Haptics.light()
            return
        }

        scanning = true
        Task { @MainActor in
            defer { scanning = false }
            do {
                guard let hit = try await database.product(barcode: code) else {
                    scanNote = .unknown
                    return
                }
                var draft = hit.draft
                // The scan supplied the code, so the row it eventually writes
                // is a barcode import even where the numbers came from the
                // database. Both facts ride on the draft, because the draft is
                // the only thing that reaches `FoodItemPick.commit`.
                draft.barcode = code
                draft.source = FoodItemSource.barcode
                add(draft)
                scanNote = .added(draft.displayName)
                Haptics.light()
            } catch is CancellationError {
                // Nothing to report.
            } catch {
                scanNote = .unreachable(error.localizedDescription)
            }
        }
    }
    #endif

    @ViewBuilder
    private func scanNoteBlock(_ note: ScanNote) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            switch note {
            case .unreadable:
                Text("Dexter could not read a barcode in that photo. Try again with the code filling more of the frame.")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)

            case .added(let name):
                Text("\(name) went straight into the meal.")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.success)
                    .fixedSize(horizontal: false, vertical: true)

            case .unknown:
                Text("The code read fine and the food database has never seen it. Close this and describe the item in words instead, then save it to your items from the meal.")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)

            case .unreachable(let message):
                // "The code read fine" is the half the user cannot see for
                // themselves; `message` already states the other half in a
                // whole sentence, so repeating "the food database" here would
                // name it twice in one line. Same severity as `.unknown`
                // above: the scan did not land, and neither case is an error
                // in anything the user did.
                Text("The code read fine. \(message)")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    private func errorBlock(_ message: String) -> some View {
        Text(message)
            .font(.edFootnote)
            .foregroundStyle(Tokens.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - The tray

    @ViewBuilder
    private var traySection: some View {
        if !picks.isEmpty {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text("Added").eyebrow()
                    Spacer(minLength: Space.sm)
                    Text("\(MealFormat.calories(trayCalories, .stated)) kcal")
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)
                        .monospacedDigit()
                }

                VStack(spacing: Space.sm) {
                    ForEach(picks) { pick in
                        trayRow(pick)
                    }
                }
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.lg)
        }
    }

    private var trayCalories: Double {
        picks.reduce(0) { $0 + $1.entry.calories }
    }

    /// One pick: its name, an editable amount, the unit, what it costs, and a
    /// way out.
    ///
    /// The amount is the one number anyone changes here, so it is a field rather
    /// than a stepper: "250" is one gesture and eleven taps of a plus button is
    /// not.
    private func trayRow(_ pick: FoodItemPick) -> some View {
        let rescalable = pick.canRescale(savedRow: savedRow(for: pick))
        return HStack(spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pick.entry.name)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(MealFormat.calories(pick.entry.calories, .stated)) kcal")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .monospacedDigit()
            }

            Spacer(minLength: Space.sm)

            TextField("0", text: amountBinding(for: pick))
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .decimalKeyboard()
                .textFieldStyle(.plain)
                .paperFieldOnMac()
                .frame(width: 64)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 4)
                .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.sm)
                // A saved pick whose row has been deleted cannot be rescaled:
                // there is nothing left to read the ratio off. The numbers
                // already on the pick stay valid, so the pick stands and only
                // the field goes. A database pick carries its own draft and is
                // never in this state.
                .disabled(!rescalable)
                .opacity(rescalable ? 1 : 0.5)
                .accessibilityLabel("Amount of \(pick.entry.name)")

            Text(pick.entry.portionUnit)
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .frame(width: 22, alignment: .leading)

            Button {
                remove(pick)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Tokens.mutedSoft)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(pick.entry.name)")
        }
    }

    private func amountBinding(for pick: FoodItemPick) -> Binding<String> {
        Binding(
            get: { amounts[pick.id] ?? MealItemDraft.string(pick.entry.portionQuantity) },
            set: { text in
                amounts[pick.id] = text
                rescale(pick.id, to: MealItemDraft.number(text))
            }
        )
    }

    /// The stored row a pick scales against, when it has one.
    private func savedRow(for pick: FoodItemPick) -> LocalFoodItem? {
        pick.savedItemUUID.flatMap { rowsByUUID[$0] }
    }

    /// Rebuild a pick's entry for a new amount.
    ///
    /// The multiplication belongs to `FoodItemPick.entry(at:savedRow:)`, which
    /// puts both origins through one ratio, so this view never does the
    /// arithmetic itself. A second implementation of it here is how one surface
    /// ends up disagreeing with the row it read from.
    ///
    /// A non-positive amount leaves the entry alone rather than zeroing it: "1."
    /// and "" are both states a field passes through on the way to a number, and
    /// blanking the row's calories on each of them makes the total flicker.
    private func rescale(_ pickID: UUID, to amount: Double) {
        guard amount > 0, let index = picks.firstIndex(where: { $0.id == pickID }) else { return }
        guard let entry = picks[index].entry(at: amount, savedRow: savedRow(for: picks[index])) else { return }
        picks[index].entry = entry
    }

    // MARK: - Picking

    private func isPicked(_ item: LocalFoodItem) -> Bool {
        isPicked(FoodItemPick.Origin.saved(itemUUID: item.clientUUID))
    }

    private func isPicked(_ draft: FoodItemDraft) -> Bool {
        isPicked(FoodItemPick.Origin.database(draft))
    }

    private func isPicked(_ origin: FoodItemPick.Origin) -> Bool {
        picks.contains { $0.subjectKey == origin.subjectKey }
    }

    private func toggle(_ item: LocalFoodItem) {
        toggle(.saved(itemUUID: item.clientUUID)) { add(item) }
    }

    private func toggle(_ draft: FoodItemDraft) {
        toggle(.database(draft)) { add(draft) }
    }

    /// One tap, one meaning: in if it is out, out if it is in.
    private func toggle(_ origin: FoodItemPick.Origin, add: () -> Void) {
        if let existing = picks.first(where: { $0.subjectKey == origin.subjectKey }) {
            remove(existing)
        } else {
            add()
            Haptics.tick()
        }
    }

    private func add(_ item: LocalFoodItem) {
        guard !isPicked(item) else { return }
        append(
            FoodItemPick(
                origin: .saved(itemUUID: item.clientUUID),
                entry: item.mealItem()
            ),
            amount: item.defaultPortionQuantity
        )
        rowsByUUID[item.clientUUID] = item
    }

    /// A hit, straight into the tray, with nothing written anywhere.
    ///
    /// This is the tap the first version of the feature put a confirm form in
    /// front of. Nothing here reaches the store: an item the user adds and then
    /// removes has to leave the library exactly as it found it, or the list
    /// fills with everything that was ever considered.
    private func add(_ draft: FoodItemDraft) {
        guard !isPicked(draft) else { return }
        append(
            FoodItemPick(origin: .database(draft), entry: draft.mealItem()),
            amount: draft.defaultPortionQuantity
        )
    }

    private func append(_ pick: FoodItemPick, amount: Double) {
        picks.append(pick)
        amounts[pick.id] = MealItemDraft.string(amount)
    }

    private func remove(_ pick: FoodItemPick) {
        picks.removeAll { $0.id == pick.id }
        amounts[pick.id] = nil
    }

    // MARK: - Loading

    private func load() {
        picks = initialPicks
        for pick in initialPicks {
            amounts[pick.id] = MealItemDraft.string(pick.entry.portionQuantity)
        }
        reloadMatches()
    }

    /// Re-read the store: the rows answering the query, and the whole set the
    /// tray rescales against.
    ///
    /// Both in one pass so a saved edit cannot show in the list while the tray
    /// still scales off the numbers it had before.
    private func reloadMatches() {
        do {
            let all = try items.allItems(includeArchived: true)
            rowsByUUID = Dictionary(uniqueKeysWithValues: all.map { ($0.clientUUID, $0) })
            libraryIsEmpty = all.isEmpty
            matches = try items.items(matching: query)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The list, re-read after the editor wrote a row.
    ///
    /// It is deliberately NOT added to the meal. Opening Edit is a correction:
    /// the user went in to fix a number, and a form that quietly put the item
    /// in tonight's dinner on the way out would be answering a question nobody
    /// asked. The old version did add, because this form was also the only way
    /// an imported item reached the tray; imports go straight in now, so the
    /// reason is gone (#625).
    ///
    /// A pick of this row that is already in the tray keeps its own copy of the
    /// numbers, exactly as a logged meal does. Retyping its amount picks the
    /// correction up, because `rescale` reads the row through `rowsByUUID`,
    /// which this refreshes.
    private func adoptEdit() {
        scanNote = nil
        reloadMatches()
    }

    // MARK: - Row actions

    private func archive(_ item: LocalFoodItem) {
        do {
            try items.setArchived(item, on: true)
            // An archived row leaves the list, so a pick of it would be a
            // choice the user can no longer see or undo.
            if let pick = picks.first(where: { $0.savedItemUUID == item.clientUUID }) {
                remove(pick)
            }
            reloadMatches()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteConfirmed() {
        guard let item = pendingDelete else { return }
        pendingDelete = nil
        do {
            if let pick = picks.first(where: { $0.savedItemUUID == item.clientUUID }) {
                remove(pick)
            }
            try items.deleteItem(item)
            reloadMatches()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Leaving

    /// The only path that hands the tray back. Cancel throws it away, which is
    /// what makes every tap in this sheet free.
    ///
    /// Note what this does NOT do: write anything. The library is written by
    /// `FoodItemPick.commit`, which the caller runs when the meal itself is
    /// written. A tray handed back and then abandoned costs nothing.
    private func commit() {
        searchTask?.cancel()
        onDone(picks)
        dismiss()
    }

    private func cancel() {
        searchTask?.cancel()
        dismiss()
    }
}

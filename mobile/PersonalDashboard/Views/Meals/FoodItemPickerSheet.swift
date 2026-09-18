import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

/// One item chosen from the library, already scaled to the chosen amount (#625).
///
/// ### Why the nutrients are carried and not the row
///
/// `entry` is a plain `MealItemEntry` with the eight numbers already worked out
/// for the amount on screen, which is the same value type an estimate produces
/// and the same one `LocalMeal` stores. So whoever receives a pick writes it the
/// way it writes any other item, and nothing downstream has to know the library
/// exists.
///
/// `itemUUID` rides along for one reason: `FoodItemService.recordUse` orders the
/// picker by what you actually eat, and it needs the row. The picker does NOT
/// call it — a pick that is still sitting in the tray has not been eaten, and
/// the counters are a claim about a meal that was written. Whoever commits the
/// meal is the only caller that can honestly make that claim.
///
/// `id` is this pick's identity in the tray, held apart from `entry.id` because
/// editing an amount rebuilds the entry (see `FoodItemPickerSheet.rescale`) and
/// a list whose rows change identity under an open keyboard loses the caret.
struct FoodItemPick: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var itemUUID: String
    var entry: MealItemEntry
}

/// Pick saved items instead of describing them (#625).
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
/// So this sheet does no estimating at all. Picking a row and pressing Done
/// makes no network call and no model call. That is the whole point, and it is
/// the property to protect if this file ever grows.
///
/// ### Why one tap adds, and a second tap removes
///
/// A row goes in at its own `defaultPortionQuantity`, which is the 150 g pot or
/// the 40 g wafer the user already told the library about. The common case is
/// therefore pick, pick, Done, with nothing typed. Tapping a row that is already
/// in the tray takes it out again, so a mis-tap costs one tap rather than a trip
/// to a second control.
///
/// Editing is NEVER a long press. The per-row menu behind the trailing glyph is
/// the one way to reach Edit, Archive and Delete, and the same menu answers a
/// right-click on the Mac. A tap means add, everywhere, with no second meaning.
///
/// ### Why the public database is a button and not a behaviour
///
/// Open Food Facts is crowd-sourced, and a hit is a proposal rather than a fact:
/// one of its entries for a high-protein vanilla yogurt claims 52 kcal per 100 g,
/// and nothing downstream can tell that from a plausible number. So it is never
/// searched per keystroke and never searched without being asked. The button
/// appears when the local library has little or nothing to offer, its results
/// sit in their own labelled section, and tapping one opens the confirm form. No
/// path from that section reaches the library or the tray without the user
/// reading the numbers first.
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

    /// The rows answering the current query, in the service's own order.
    @State private var matches: [LocalFoodItem] = []

    /// Every row in the store, archived ones included, keyed by `clientUUID`.
    ///
    /// The tray reads this to rescale, and it has to include archived rows: an
    /// item retired after it was picked must still be able to answer "what are
    /// 200 g of you", or the amount field on a pick already made would go dead.
    @State private var rowsByUUID: [String: LocalFoodItem] = [:]

    /// True when the store holds nothing at all, which is a different state from
    /// "nothing matches what you typed" and gets a different screen.
    @State private var libraryIsEmpty = false

    @State private var picks: [FoodItemPick] = []

    /// The amount each pick is being edited at, as text.
    ///
    /// Text rather than a `Double` for the reason `MealNumberField` exists: a
    /// half-typed "1." is not a number, and a formatted binding rewrites the
    /// field under the caret when it cannot parse one.
    @State private var amounts: [UUID: String] = [:]

    @State private var remote: RemotePhase = .idle
    @State private var remoteResults: [FoodItemDraft] = []
    @State private var remoteTask: Task<Void, Never>?

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

    /// Where the public search has got to.
    ///
    /// Cancellation is deliberately NOT a case. A search the user replaced is
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

    /// What a barcode scan came to, in the three outcomes worth a sentence.
    ///
    /// A scan that opened the confirm form needs none of these: the form is the
    /// answer. These are the branches that would otherwise end nowhere.
    private enum ScanNote: Identifiable, Equatable {
        /// The photo held no code this device could read.
        case unreadable
        /// A row in the library already carried that code, and it went straight
        /// into the tray.
        case alreadyKnown(String)
        /// The code read fine and the database could not be reached. The code is
        /// kept so the user can still type the packet in.
        case unreachable(barcode: String, message: String)

        var id: String {
            switch self {
            case .unreadable:                    return "unreadable"
            case .alreadyKnown(let name):        return "known-\(name)"
            case .unreachable(let barcode, _):   return "unreachable-\(barcode)"
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
                        librarySection
                        databaseSection
                        traySection
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle("Saved items")
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
                        Button("New item") { editorTarget = .new }
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
            // Local only, and instant. The public database is never searched on
            // a keystroke; see the note on the type.
            reloadMatches()
        }
        .sheet(item: $editorTarget) { target in
            FoodItemEditorSheet(target: target) { saved in
                editorTarget = nil
                adopt(saved)
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

    private static let searchExample = "Search your saved items"

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

    // MARK: - The library

    @ViewBuilder
    private var librarySection: some View {
        if libraryIsEmpty {
            emptyLibraryBlock
        } else if matches.isEmpty {
            noMatchesBlock
        } else {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Your items").eyebrow()
                VStack(spacing: 0) {
                    ForEach(matches, id: \.clientUUID) { item in
                        libraryRow(item)
                        if item.clientUUID != matches.last?.clientUUID {
                            Rectangle()
                                .fill(Tokens.divider)
                                .frame(height: 0.5)
                        }
                    }
                }
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.lg)
            }
        }
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
                    Image(systemName: picked ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(picked ? Tokens.accentMeals : Tokens.mutedSoft)
                        .frame(width: 22, height: 22)

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
            .accessibilityValue(picked ? "In the tray" : "Not in the tray")
            .accessibilityHint(picked ? "Removes it from the tray" : "Adds one usual serving to the tray")

            rowMenu(item)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        // Right-clicking the row reaches the same three actions on the Mac.
        .contextMenu { rowActions(item) }
    }

    /// The usual serving and what it costs: "150 g · 148 kcal · 15 g protein".
    ///
    /// Stated precision, not estimate precision. These numbers came off a packet
    /// rather than out of a portion guess, and rounding 148 to 150 would destroy
    /// the one property that makes the library worth keeping (#594).
    private func servingLine(_ item: LocalFoodItem) -> String {
        let n = item.defaultNutrients
        return [
            "\(MealItemDraft.string(item.defaultPortionQuantity)) \(item.unit.rawValue)",
            "\(MealFormat.calories(n.calories, .stated)) kcal",
            "\(MealFormat.grams(n.proteinG)) g protein"
        ].joined(separator: "  ·  ")
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

    /// Nothing in the store yet. One line saying what the library is for, and
    /// both ways in.
    private var emptyLibraryBlock: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Keep the packets you eat often here, and log them without describing them again.")
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.sm) {
                Button("New item") { editorTarget = .new }
                    .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                Button("Search the food database") { searchDatabase() }
                    .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                    .disabled(trimmedQuery.isEmpty || remote == .searching)
            }
            if trimmedQuery.isEmpty {
                Text("Type a name above to search the public food database.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    /// The store has rows and none of them answer the query.
    private var noMatchesBlock: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(trimmedQuery.isEmpty
                 ? "Every saved item is archived. Unarchive one by editing it, or add a new one."
                 : "Nothing in your saved items matches \"\(trimmedQuery)\".")
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.sm) {
                Button("New item") { editorTarget = .new }
                    .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                if !trimmedQuery.isEmpty {
                    Button("Search the food database") { searchDatabase() }
                        .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                        .disabled(remote == .searching)
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    // MARK: - The public database

    /// True when the local library had little to offer, which is the only state
    /// the database button appears in.
    ///
    /// Two matches rather than none, because "protein bar" finding one flavour
    /// out of a range is exactly the moment someone wants the database, and a
    /// zero-only test would hide the button behind a delete.
    private var couldUseDatabase: Bool {
        !trimmedQuery.isEmpty && !libraryIsEmpty && !matches.isEmpty && matches.count <= 2
    }

    /// The button and whatever the last press came to, under one root.
    ///
    /// One container rather than two loose statements: a multi-statement
    /// `@ViewBuilder` flattens into its parent, and anything later attached to
    /// this property would then be applied to each child separately (#597).
    @ViewBuilder
    private var databaseSection: some View {
        if couldUseDatabase || remote != .idle {
            VStack(alignment: .leading, spacing: Space.md) {
                if couldUseDatabase && remote == .idle {
                    Button("Search the food database") { searchDatabase() }
                        .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm, fullWidth: true))
                }
                remotePhase
            }
        }
    }

    @ViewBuilder
    private var remotePhase: some View {
        switch remote {
        case .idle:
            EmptyView()

        case .searching:
            HStack(spacing: Space.sm) {
                ProgressView()
                    #if os(macOS)
                    .controlSize(.small)
                    #else
                    .scaleEffect(0.7)
                    #endif
                Text("Asking the public food database.")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
            }
            .accessibilityElement(children: .combine)

        case .failed(let message):
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(message)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.sm) {
                    Button("Try again") { searchDatabase() }
                        .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                    Button("Type it in yourself") { editorTarget = .new }
                        .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
                }
            }

        case .answered(let answered):
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("From the food database").eyebrow()
                Text("Open Food Facts is public and crowd-sourced, so these numbers are a proposal. Pick one to read it against the packet before it is saved.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .fixedSize(horizontal: false, vertical: true)

                if remoteResults.isEmpty {
                    Text("The database has nothing for \"\(answered)\". You can still type the packet in yourself.")
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("New item") { editorTarget = .new }
                        .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(remoteResults.enumerated()), id: \.offset) { pair in
                            databaseRow(pair.element)
                            if pair.offset != remoteResults.count - 1 {
                                Rectangle()
                                    .fill(Tokens.divider)
                                    .frame(height: 0.5)
                            }
                        }
                    }
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                    .paperBorder(Tokens.border, radius: Radius.lg)
                }
            }
        }
    }

    /// One database hit. Tapping it opens the confirm form, never the library.
    private func databaseRow(_ draft: FoodItemDraft) -> some View {
        Button {
            editorTarget = .draft(draft)
        } label: {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Tokens.mutedSoft)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(draftTitle(draft))
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(draftLine(draft))
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.mutedSoft)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(draftTitle(draft))
        .accessibilityHint("Opens the numbers so you can check them before saving")
    }

    private func draftTitle(_ draft: FoodItemDraft) -> String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? "Unnamed product" : name
        guard let brand = draft.brand, !brand.isEmpty else { return title }
        if title.lowercased().hasPrefix(brand.lowercased()) { return title }
        return "\(brand) \(title)"
    }

    private func draftLine(_ draft: FoodItemDraft) -> String {
        var parts = [
            "\(MealFormat.calories(draft.calories, .stated)) kcal per \(MealItemDraft.string(draft.basePortionQuantity)) \(draft.basePortionUnit.rawValue)"
        ]
        if !draft.missingNutrients.isEmpty {
            parts.append("\(draft.missingNutrients.count) figures not stated")
        }
        return parts.joined(separator: "  ·  ")
    }

    /// The one call in this file that reaches the network, and it only runs from
    /// a button.
    ///
    /// The previous task is cancelled first, so a second press replaces the
    /// answer rather than racing it. A cancelled call is not a failure and never
    /// reaches `remote`: `OpenFoodFactsClient` throws `CancellationError` for
    /// it, which is caught and dropped here.
    private func searchDatabase() {
        let term = trimmedQuery
        guard !term.isEmpty else { return }
        remoteTask?.cancel()
        remote = .searching
        remoteResults = []

        remoteTask = Task { @MainActor in
            do {
                let hits = try await database.search(term)
                try Task.checkCancellation()
                remoteResults = hits.map(\.draft)
                remote = .answered(term)
            } catch is CancellationError {
                // The user moved on. Nothing to report and nothing to reset:
                // whoever cancelled us has already set the next phase.
            } catch {
                remote = .failed(error.localizedDescription)
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

    /// What a photo of a packet comes to, in four branches that all end
    /// somewhere the user can act.
    ///
    /// 1. Nothing was captured: the user cancelled, and nothing is said.
    /// 2. No code in the frame: a sentence saying so, and the button is still
    ///    there.
    /// 3. A code the library already knows: straight into the tray, with the row
    ///    named so it is obvious nothing was created.
    /// 4. A code the library does not know: the database is asked, and either
    ///    way the confirm form opens, prefilled from the hit or holding just the
    ///    code.
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
            scanNote = .alreadyKnown(known.displayName)
            Haptics.light()
            return
        }

        scanning = true
        Task { @MainActor in
            defer { scanning = false }
            do {
                if let hit = try await database.product(barcode: code) {
                    var draft = hit.draft
                    // The scan supplied the code, so the row it writes is a
                    // barcode import even where the numbers came from the
                    // database. Carrying it on the draft keeps the editor from
                    // needing a second parameter to say so.
                    draft.barcode = code
                    editorTarget = .scannedDraft(draft)
                } else {
                    editorTarget = .newBarcode(code)
                }
            } catch is CancellationError {
                // Nothing to report.
            } catch {
                scanNote = .unreachable(barcode: code, message: error.localizedDescription)
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

            case .alreadyKnown(let name):
                Text("\(name) was already saved, so it went straight into the tray.")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.success)
                    .fixedSize(horizontal: false, vertical: true)

            case .unreachable(let barcode, let message):
                Text("The code read fine and the food database could not be reached. \(message)")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Type this packet in") { editorTarget = .newBarcode(barcode) }
                    .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
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
                    Text("Picked").eyebrow()
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
        let row = rowsByUUID[pick.itemUUID]
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
                // A row whose item has been deleted cannot be rescaled: there is
                // nothing left to read the ratio off. The numbers already on the
                // pick stay valid, so the pick stands and only the field goes.
                .disabled(row == nil)
                .opacity(row == nil ? 0.5 : 1)
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

    /// Rebuild a pick's entry for a new amount.
    ///
    /// The multiplication belongs to `LocalFoodItem.nutrients(for:)` and is
    /// reached through `mealItem(quantity:)`, so this view never does the
    /// arithmetic itself. A second implementation of the ratio here is how one
    /// surface ends up disagreeing with the row it read from.
    ///
    /// A non-positive amount leaves the entry alone rather than zeroing it: "1."
    /// and "" are both states a field passes through on the way to a number, and
    /// blanking the row's calories on each of them makes the total flicker.
    private func rescale(_ pickID: UUID, to amount: Double) {
        guard amount > 0,
              let index = picks.firstIndex(where: { $0.id == pickID }),
              let row = rowsByUUID[picks[index].itemUUID] else { return }
        picks[index].entry = row.mealItem(quantity: amount)
    }

    // MARK: - Picking

    private func isPicked(_ item: LocalFoodItem) -> Bool {
        picks.contains { $0.itemUUID == item.clientUUID }
    }

    private func toggle(_ item: LocalFoodItem) {
        if let existing = picks.first(where: { $0.itemUUID == item.clientUUID }) {
            remove(existing)
        } else {
            add(item)
            Haptics.tick()
        }
    }

    private func add(_ item: LocalFoodItem) {
        guard !isPicked(item) else { return }
        let pick = FoodItemPick(
            itemUUID: item.clientUUID,
            entry: item.mealItem()
        )
        picks.append(pick)
        amounts[pick.id] = MealItemDraft.string(item.defaultPortionQuantity)
        rowsByUUID[item.clientUUID] = item
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

    /// A row the editor just wrote: into the list, and into the tray.
    ///
    /// The tray part is the point of the whole detour. Somebody who scanned a
    /// packet or searched the database was logging a meal, not curating a
    /// library, and leaving them back at the search box with the item merely
    /// saved would make them find and tap it again.
    private func adopt(_ item: LocalFoodItem) {
        remote = .idle
        remoteResults = []
        scanNote = nil
        reloadMatches()
        if !item.isArchived { add(item) }
    }

    // MARK: - Row actions

    private func archive(_ item: LocalFoodItem) {
        do {
            try items.setArchived(item, on: true)
            // An archived row leaves the picker, so a pick of it would be a
            // choice the user can no longer see or undo.
            if let pick = picks.first(where: { $0.itemUUID == item.clientUUID }) {
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
            if let pick = picks.first(where: { $0.itemUUID == item.clientUUID }) {
                remove(pick)
            }
            try items.deleteItem(item)
            reloadMatches()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Leaving

    /// The only path that commits. Cancel throws the tray away, which is what
    /// makes every tap in this sheet free.
    private func commit() {
        remoteTask?.cancel()
        onDone(picks)
        dismiss()
    }

    private func cancel() {
        remoteTask?.cancel()
        dismiss()
    }
}

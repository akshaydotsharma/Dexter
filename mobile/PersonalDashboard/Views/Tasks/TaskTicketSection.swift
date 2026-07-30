import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
// For the camera-availability gate on the add menu.
import UIKit
#endif

/// A file picked outside the task editor, on its way in to be read (#402).
///
/// Carries the bytes rather than a URL because the picker's security-scoped access
/// ends when it dismisses, and the editor is presented after that.
struct TaskDocumentUpload: Identifiable, Equatable {
    let id: UUID
    let data: Data
    let isPDF: Bool

    init(data: Data, isPDF: Bool) {
        self.id = UUID()
        self.data = data
        self.isPDF = isPDF
    }
}

/// Blocking notice shown over the task editor's form while a file picked from the
/// plus menu is being read (#402).
///
/// The inline spinner in the attachments section is not enough for this case. The
/// editor opens on its own with every field empty, and the one thing saying why is
/// a small spinner next to a section heading — on the Mac's 360-point popover that
/// section can be below the fold, so it is somewhere you cannot even see. What the
/// person is looking at reads as a form that failed to load.
///
/// Deliberately scoped to the form and NOT the toolbar, so Cancel stays reachable.
/// The read has no timeout of its own and a stalled network would otherwise trap
/// someone behind a spinner with no way out.
///
/// Takes the card-and-spinner shape from `TripDetailView`'s ticket-processing
/// overlay, so the two reads look like the same operation — which they are — but
/// dims harder than that one does. At the 0.12 scrim the trip overlays use, this
/// card and the form behind it read as competing for the same space: the editor is
/// dense with rounded cards in a similar tone, so a floating card needs the form to
/// visibly recede rather than merely tint. The caller pairs this with a blur, which
/// is what actually stops the text behind from competing.
struct TaskDocumentReadingOverlay: View {
    let isPDF: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: Space.md) {
                ProgressView()
                    .tint(Tokens.accent(for: .tasks))
                VStack(spacing: Space.xs) {
                    Text(isPDF ? "Reading from file…" : "Reading from image…")
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)
                    Text("Filling in what it says.")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                }
                .multilineTextAlignment(.center)
            }
            .padding(Space.xl)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.lg)
            .shadowLg()
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isPDF
                ? "Reading the file and filling in the task."
                : "Reading the image and filling in the task."
        )
    }
}

/// A read in flight, and what it is reading (#416). Carried rather than a bare Bool
/// so the notice can say "file" or "image" without the presenter holding a second
/// piece of state that could disagree with the first.
struct TaskReadingNotice: Equatable {
    let isPDF: Bool
}

/// File attachments for a task, shown as a stack of wallet cards inside the task
/// editor with an add control (#399, generalised in #402).
///
/// Owns its own reads and writes through `TaskTicketService` rather than routing
/// them through `TasksViewModel`, for the reason `NoteImageStrip` does the same
/// (#395): attachments are scoped to the one task on screen, while the view
/// model's cached `todos` array is about the index.
///
/// Cards are stacked vertically rather than in a horizontal strip, because a
/// wallet card is a portrait object and the point of the feature is that it is
/// legible at a glance.
///
/// ## Getting a file in
///
/// Four ways, in the order people reach for them: it arrives with the task from the
/// plus menu (`initialDocument`), or it is dropped on the section, picked from
/// Finder / Files, or photographed (iPhone only). There is no separate "image" and
/// "PDF" entry — one file picker accepts either, because the distinction is not a
/// choice worth surfacing. See `TicketFilePicker`.
///
/// ## Attaching to a task that does not exist yet
///
/// An attachment added while composing a NEW task is held in `pending` and written
/// only when the editor is committed. An earlier version created the task the moment
/// a file arrived, which meant Cancel left a task behind — the editor deciding on the
/// person's behalf that they had finished. The file still reads immediately, so the
/// parsed title, date and venue fill the form straight away; it is only the write
/// that waits. This is also what makes "create a task from a document" work: the
/// draft is a real card and real fields with nothing yet committed.
struct TaskTicketSection: View {
    /// The owning task, or `nil` when the editor is for a task that has not been
    /// saved yet.
    let todoId: UUID?
    /// Everything the app already knows about the event, which the extractor uses to
    /// fill what the file does not show (#408). Carries the title the cards fall
    /// back to, so it replaces the plain `taskTitle` this took before.
    let context: TaskTicketContext
    /// Tickets read but not yet written, owned by the editor because it owns the
    /// Cancel / Add lifecycle that decides their fate. Always empty once `todoId`
    /// is non-nil.
    @Binding var pending: [TaskTicket]
    /// Hands the values read off the ticket up to the editor so the task's own
    /// fields fill in: title, due date, address. The whole point of uploading is
    /// that you should not then have to type what the ticket already says.
    var onExtracted: (TaskTicketRead) -> Void = { _ in }
    /// A file chosen before the editor opened, read as soon as the section appears
    /// (#402). This is the "create a task from a document" path: the editor is on
    /// screen with its spinner running rather than the person waiting on a blank
    /// screen for a parse they cannot see.
    var initialDocument: TaskDocumentUpload? = nil
    /// The read in flight, so the editor can say so across its whole form (#416).
    ///
    /// EVERY read announces now, not just one that arrived with the editor. The
    /// original reasoning — you are already looking at the section, so a small inline
    /// spinner is proportionate — assumed you had been looking at it the whole time.
    /// You have not: you have been in Finder, and you come back to a popover that has
    /// to tell you what it is doing. Carries `isPDF` so the notice can name what it is
    /// reading.
    var reading: Binding<TaskReadingNotice?>? = nil
    /// Reports that this section is mid-operation: a picker is open, or a read is in
    /// flight (#408, #416).
    ///
    /// On macOS this is what holds the editor popover open. `MacAnchoredPopover`
    /// switches to `.applicationDefined` while busy, so neither Finder taking key nor
    /// a stray click behind it can bin a read that is already running. On iOS it
    /// drives `interactiveDismissDisabled` on the sheet, for the stray-click half of
    /// the same problem.
    var isBusy: Binding<Bool>? = nil

    @State private var stored: [TaskTicket] = []
    @State private var selected: TaskTicket?
    @State private var isIngesting = false
    @State private var isTargetedForDrop = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    /// The attachment the long-press / right-click menu offered to remove, held for
    /// the confirmation (#408). Removing deletes the file off the device, so it is
    /// confirmed here the same way it is in the detail sheet.
    @State private var pendingRemoval: TaskTicket?
    /// True from presenting a picker until it hands something back (or is cancelled).
    /// Part of `isBusy`: on macOS the panel outlives the view that opened it, so the
    /// window between the two is exactly when the editor must not be dismissed.
    @State private var awaitingPick = false
    /// `onAppear` can fire more than once for the same view; the document must be
    /// read exactly once or it would be stored and attached twice.
    @State private var consumedInitialDocument = false
    /// The in-flight read, so dismissing the editor can cancel it. The file is on
    /// disk before the read returns, so a read nobody is waiting for any more has to
    /// clean up after itself.
    @State private var ingestTask: Task<Void, Never>?

    #if os(iOS)
    @State private var showingCamera = false
    @State private var showingPhotoLibrary = false
    #endif
    @State private var showingFilePicker = false

    private let service = TaskTicketService()

    private var accent: Color { Tokens.accent(for: .tasks) }

    /// The task's title, which the cards fall back to for their headline.
    private var taskTitle: String { context.title }

    /// Whether an operation is in progress that the editor must stay open for.
    private var isBusyNow: Bool { isIngesting || awaitingPick }

    /// Everything on screen: what is on disk, then what is waiting to be.
    private var tickets: [TaskTicket] { stored + pending }

    private func isPending(_ ticket: TaskTicket) -> Bool {
        pending.contains { $0.id == ticket.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack(spacing: Space.sm) {
                Text("Attachments").eyebrow()
                if isIngesting {
                    ProgressView().scaleEffect(0.7)
                    Text("Reading the file…")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                }
                Spacer(minLength: 0)
                addControl
            }

            if tickets.isEmpty && !isIngesting {
                emptyHint
            } else {
                VStack(spacing: Space.md) {
                    ForEach(tickets) { ticket in
                        cardButton(for: ticket)
                    }
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Drop a ticket straight onto the section. Accepting `URL` rather than
        // `Data` is what makes a Finder drag work: the system hands over a file
        // reference, and we read the bytes ourselves.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            ingest(url: url)
            return true
        } isTargeted: { targeted in
            isTargetedForDrop = targeted
        }
        .animation(.easeOut(duration: 0.15), value: isTargetedForDrop)
        // Keep the presenter informed for as long as there is work to lose.
        .onChange(of: isBusyNow) { _, busy in
            isBusy?.wrappedValue = busy
        }
        .confirmationDialog(
            "Remove this attachment?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove attachment", role: .destructive) {
                if let ticket = pendingRemoval { remove(ticket) }
                pendingRemoval = nil
            }
            Button("Keep it", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("The file will be deleted from this device. The task itself stays.")
        }
        .onAppear {
            reload()
            // Read a file handed in from the plus menu. Deliberately does NOT open
            // the ticket sheet afterwards: the person asked to see the draft task,
            // and a sheet over it would hide the thing they came to check.
            if let initialDocument, !consumedInitialDocument {
                consumedInitialDocument = true
                ingest(data: initialDocument.data, isPDF: initialDocument.isPDF, autoOpen: false)
            }
        }
        .onDisappear {
            ingestTask?.cancel()
            // Never leave the presenter pinned open by a section that is gone.
            awaitingPick = false
            isBusy?.wrappedValue = false
            reading?.wrappedValue = nil
            TaskAttachmentActivity.shared.ended()
        }
        .sheet(item: $selected) { ticket in
            // A pending ticket has no row to write to, so its edits and its removal
            // are applied to the editor's in-memory copy instead.
            if isPending(ticket) {
                TaskTicketDetailSheet(
                    ticket: ticket,
                    taskTitle: taskTitle,
                    onChange: {},
                    onSave: { edited in
                        if let i = pending.firstIndex(where: { $0.id == edited.id }) {
                            pending[i] = edited
                        }
                    },
                    onDelete: {
                        if let i = pending.firstIndex(where: { $0.id == ticket.id }) {
                            service.discardUnattached(pending[i])
                            pending.remove(at: i)
                        }
                    }
                )
            } else {
                TaskTicketDetailSheet(
                    ticket: ticket,
                    taskTitle: taskTitle,
                    onChange: reload
                )
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { data in
                awaitingPick = false
                ingest(data: data, isPDF: false)
            }
        }
        .photoLibraryPicker(isPresented: $showingPhotoLibrary) { data in
            awaitingPick = false
            ingest(data: data, isPDF: false)
        }
        #endif
        .ticketFilePicker(isPresented: $showingFilePicker) { data, isPDF in
            // Cleared FIRST, and on every outcome including cancel: this is what
            // releases the editor once the panel is done with, and a path that
            // forgot it would pin the popover open for good.
            awaitingPick = false
            ingest(data: data, isPDF: isPDF)
        }
    }

    // MARK: - Pieces

    /// On macOS this is a single button, because there is exactly one sensible
    /// source: a file. On iPhone it stays a menu, because camera and photo library
    /// are genuinely different places a ticket lives and neither is reachable
    /// through the file picker.
    @ViewBuilder
    private var addControl: some View {
        #if os(iOS)
        Menu {
            // Same gate the trip ticket menu uses: a simulator has no camera and
            // the row would otherwise present an empty picker.
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    Haptics.light()
                    awaitingPick = true
                    showingCamera = true
                } label: {
                    Label("Take a photo", systemImage: "camera")
                }
            }
            Button {
                Haptics.light()
                awaitingPick = true
                showingPhotoLibrary = true
            } label: {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                Haptics.light()
                awaitingPick = true
                showingFilePicker = true
            } label: {
                Label("Choose a file", systemImage: "folder")
            }
        } label: {
            addLabel
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isIngesting)
        .accessibilityLabel("Add an attachment to this task")
        #else
        Button {
            // Set BEFORE the panel is asked for, so the editor is already pinned by
            // the time the panel takes key focus away from it (#408).
            awaitingPick = true
            showingFilePicker = true
        } label: {
            addLabel
        }
        .buttonStyle(.plain)
        .disabled(isIngesting)
        .accessibilityLabel("Choose an image or PDF")
        #endif
    }

    private var addLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
            Text("Add")
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.2)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(accent.opacity(0.12), in: Capsule(style: .continuous))
        .contentShape(Capsule())
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Drop a file here, or use Add.")
                .font(.edCaption)
                .foregroundStyle(isTargetedForDrop ? accent : Tokens.inkSoft)
            Text("An image or a PDF. Dexter reads the details off it, and turns a barcode into a card you can scan at the door.")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isTargetedForDrop ? accent.opacity(0.10) : Tokens.surface2,
            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(
                    isTargetedForDrop ? accent : Tokens.border,
                    style: StrokeStyle(lineWidth: isTargetedForDrop ? 1.5 : 0.5,
                                       dash: isTargetedForDrop ? [] : [4, 3])
                )
        )
    }

    private func cardButton(for ticket: TaskTicket) -> some View {
        Button {
            Haptics.light()
            selected = ticket
        } label: {
            TaskTicketCardView(
                ticket: ticket,
                taskTitle: taskTitle,
                fileIsPresent: service.fileURL(for: ticket) != nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open attachment \(ticket.displayTitle(fallback: taskTitle))")
        // Long-press on iPhone, right-click on the Mac: View and Remove on the card
        // itself (#408). Removing WAS only reachable by opening the card, going to its
        // actions and confirming, which is a long way round for the thing you most
        // want when a card should not be there at all — a duplicate.
        //
        // Tap still opens the card. This is additive, and the detail sheet keeps its
        // own Remove action for whoever is already in there.
        .contextMenu {
            Button {
                selected = ticket
            } label: {
                Label("View attachment", systemImage: "doc.text.magnifyingglass")
            }
            Button(role: .destructive) {
                pendingRemoval = ticket
            } label: {
                Label("Remove attachment", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        guard let id = todoId else {
            stored = []
            return
        }
        do {
            stored = try service.list(todoId: id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Read a dropped file and ingest it. Mirrors the picker's own read so a drop
    /// and a pick land in exactly the same place.
    private func ingest(url: URL) {
        let needsRelease = url.startAccessingSecurityScopedResource()
        defer { if needsRelease { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Couldn't read that file."
            return
        }
        ingest(data: data, isPDF: TicketFilePickerModifier.isPDF(url))
    }

    /// Run one upload through the pipeline. A failed LLM read is not an error:
    /// the attachment still exists with the file and any barcode, and its sheet
    /// opens into the form so the details can be typed in.
    ///
    /// `autoOpen` surfaces that form immediately for a read the model could make
    /// nothing of, which is the case where there is nothing to look at and
    /// everything to fill in. Off for a file that created the task, where the draft
    /// itself is what the person is waiting to see.
    ///
    private func ingest(
        data: Data?,
        isPDF: Bool,
        autoOpen: Bool = true
    ) {
        guard let data, !data.isEmpty else { return }

        // Refuse a file this task already has, BEFORE storing or reading it (#408).
        // Cheap, and it is the case that actually happened: the first attach looked
        // like it had done nothing, so it was done again and the task ended up with
        // two identical cards.
        if let existing = service.duplicate(of: data, among: tickets) {
            statusMessage = nil
            errorMessage = Self.duplicateMessage(existing, fallback: taskTitle)
            return
        }

        isIngesting = true
        statusMessage = nil
        errorMessage = nil
        reading?.wrappedValue = TaskReadingNotice(isPDF: isPDF)
        // Also app-wide, so the window behind the popover dims and stops taking
        // clicks for the duration (#416).
        TaskAttachmentActivity.shared.began(isPDF: isPDF)

        ingestTask = Task {
            // A `defer` rather than a line on each exit: the notice blocks the form,
            // so a path that forgot to clear it would strand the person behind a
            // spinner.
            defer {
                isIngesting = false
                reading?.wrappedValue = nil
                TaskAttachmentActivity.shared.ended()
            }
            do {
                // 1. Read the ticket FIRST. This step needs no task at all, which
                //    is exactly why it is separate: the ticket is what tells us
                //    what the task should be called.
                let read = try await service.read(
                    data: data,
                    isPDF: isPDF,
                    context: context
                )

                // The editor can be dismissed while this is in flight, and Cancel is
                // the way out of a read that has stalled. The file is already on disk
                // by now, so leaving here without deleting it strands the bytes for a
                // task that will never exist.
                if Task.isCancelled {
                    service.discardStoredFile(at: read.attachmentPath)
                    return
                }

                // The other half of the duplicate check (#408), and it can only run
                // here: the barcode is not known until Vision has decoded it. This is
                // what catches the same ticket arriving as a different file — a fresh
                // screenshot, a re-download — and any row written before ingest
                // fingerprints existed. The bytes go back out, since nothing is going
                // to reference them.
                if let existing = service.duplicate(ofBarcode: read.barcodePayload, among: tickets) {
                    service.discardStoredFile(at: read.attachmentPath)
                    errorMessage = Self.duplicateMessage(existing, fallback: taskTitle)
                    return
                }

                // 2. Push what it said up into the editor's own fields, so title,
                //    due date and address fill themselves in. Uploading a ticket
                //    and then being asked to type what it says is the bug.
                onExtracted(read)

                // 3. Write it if the task exists; otherwise hold it until the
                //    editor is committed, so Cancel really cancels.
                let addedId: UUID
                if let id = todoId {
                    let ticket = read.ticket(todoId: id, position: stored.count)
                    addedId = try service.attach(ticket, todoId: id)
                    reload()
                } else {
                    // A placeholder owner id: the real one is not known yet and is
                    // substituted when the pending ticket is flushed.
                    let ticket = read.ticket(todoId: UUID(), position: pending.count)
                    pending.append(ticket)
                    addedId = ticket.id
                }

                statusMessage = read.degradeMessage
                // A read that yielded nothing opens its form, since a card blank
                // apart from a barcode has nothing to look at. A good read does
                // not: its card is already on screen and a sheet over it would just
                // be something else to dismiss.
                if autoOpen, read.extracted == nil,
                   let added = tickets.first(where: { $0.id == addedId }) {
                    selected = added
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Remove an attachment, from wherever it currently lives.
    ///
    /// A pending ticket has no row, so it goes out of the editor's array and its
    /// bytes off the disk; a stored one is soft-deleted through the service so the
    /// removal propagates the way every other delete does. Same split the detail
    /// sheet makes.
    private func remove(_ ticket: TaskTicket) {
        if let index = pending.firstIndex(where: { $0.id == ticket.id }) {
            service.discardUnattached(pending[index])
            pending.remove(at: index)
            statusMessage = nil
            errorMessage = nil
            return
        }
        do {
            try service.delete(ticket)
            reload()
            statusMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// What to say when the file is already on this task. Names the card it matched
    /// so the claim is checkable rather than something the person has to take on
    /// trust while looking at a list of similar cards.
    private static func duplicateMessage(_ existing: TaskTicket, fallback: String) -> String {
        let name = existing.displayTitle(fallback: fallback)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "That file is already attached to this task."
            : "That file is already attached to this task, as \"\(trimmed)\"."
    }
}

/// Standalone sheet wrapping the section, presented from the pass chip on a task
/// row (#399).
///
/// The chip exists so the card is reachable from the list rather than only from
/// inside the editor: at a gate the sequence should be chip, card, scanner, not a
/// detour through a form. Reusing the section here rather than writing a
/// read-only variant also means a ticket can be added from this sheet, which is
/// where someone will look for it once they know a task already has one.
struct TaskTicketsSheet: View {
    let todoId: UUID
    /// The whole task, not just its title: a file added from here is read against
    /// everything the task knows, exactly as one added from the editor is (#408).
    let context: TaskTicketContext

    @Environment(\.dismiss) private var dismiss

    @State private var reading: TaskReadingNotice?

    private var taskTitle: String { context.title }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()

                ScrollView {
                    // The task already exists here, so nothing is ever pending.
                    TaskTicketSection(
                        todoId: todoId,
                        context: context,
                        pending: .constant([]),
                        reading: $reading
                    )
                    .padding(Space.lg)
                }
                .blur(radius: reading == nil ? 0 : 4)

                if let reading {
                    TaskDocumentReadingOverlay(isPDF: reading.isPDF)
                }
            }
            .animation(.easeOut(duration: 0.2), value: reading)
            .navigationTitle(taskTitle)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }
}

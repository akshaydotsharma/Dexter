import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
// For the camera-availability gate on the add menu.
import UIKit
#endif

/// Ticket attachments for a task, shown as a stack of wallet cards inside the
/// task editor with an add control (#399).
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
/// Three ways, in the order people reach for them: drop a file on the section,
/// pick one from Finder / Files, or take a photo (iPhone only). There is no
/// separate "image" and "PDF" entry — one file picker accepts either, because the
/// distinction is not a choice worth surfacing. See `TicketFilePicker`.
///
/// ## Attaching to a task that does not exist yet
///
/// A ticket added while composing a NEW task is held in `pending` and written only
/// when the editor is committed. An earlier version created the task the moment a
/// file arrived, which meant Cancel left a task behind — the editor deciding on the
/// person's behalf that they had finished. The ticket still reads immediately, so
/// the parsed title, date and venue fill the form straight away; it is only the
/// write that waits.
struct TaskTicketSection: View {
    /// The owning task, or `nil` when the editor is for a task that has not been
    /// saved yet.
    let todoId: UUID?
    let taskTitle: String
    /// Tickets read but not yet written, owned by the editor because it owns the
    /// Cancel / Add lifecycle that decides their fate. Always empty once `todoId`
    /// is non-nil.
    @Binding var pending: [TaskTicket]
    /// Hands the values read off the ticket up to the editor so the task's own
    /// fields fill in: title, due date, address. The whole point of uploading is
    /// that you should not then have to type what the ticket already says.
    var onExtracted: (TaskTicketRead) -> Void = { _ in }

    @State private var stored: [TaskTicket] = []
    @State private var selected: TaskTicket?
    @State private var isIngesting = false
    @State private var isTargetedForDrop = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    #if os(iOS)
    @State private var showingCamera = false
    @State private var showingPhotoLibrary = false
    #endif
    @State private var showingFilePicker = false

    private let service = TaskTicketService()

    private var accent: Color { Tokens.accent(for: .tasks) }

    /// Everything on screen: what is on disk, then what is waiting to be.
    private var tickets: [TaskTicket] { stored + pending }

    private func isPending(_ ticket: TaskTicket) -> Bool {
        pending.contains { $0.id == ticket.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack(spacing: Space.sm) {
                Text("Tickets").eyebrow()
                if isIngesting {
                    ProgressView().scaleEffect(0.7)
                    Text("Reading the ticket…")
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
        .onAppear(perform: reload)
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
                ingest(data: data, isPDF: false)
            }
        }
        .photoLibraryPicker(isPresented: $showingPhotoLibrary) { data in
            ingest(data: data, isPDF: false)
        }
        #endif
        .ticketFilePicker(isPresented: $showingFilePicker) { data, isPDF in
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
                    showingCamera = true
                } label: {
                    Label("Take a photo", systemImage: "camera")
                }
            }
            Button {
                Haptics.light()
                showingPhotoLibrary = true
            } label: {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                Haptics.light()
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
        .accessibilityLabel("Add a ticket to this task")
        #else
        Button {
            showingFilePicker = true
        } label: {
            addLabel
        }
        .buttonStyle(.plain)
        .disabled(isIngesting)
        .accessibilityLabel("Choose a ticket image or PDF")
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
            Text("Drop a ticket here, or use Add.")
                .font(.edCaption)
                .foregroundStyle(isTargetedForDrop ? accent : Tokens.inkSoft)
            Text("An image or a PDF. Dexter reads the details off it and gives you a card you can scan at the door.")
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
        .accessibilityLabel("Open ticket \(ticket.displayTitle(fallback: taskTitle))")
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
    /// the row still exists with the file and any barcode, and the detail sheet
    /// opens into its form so the details can be typed in.
    private func ingest(data: Data?, isPDF: Bool) {
        guard let data, !data.isEmpty else { return }
        isIngesting = true
        statusMessage = nil
        errorMessage = nil

        Task {
            do {
                // 1. Read the ticket FIRST. This step needs no task at all, which
                //    is exactly why it is separate: the ticket is what tells us
                //    what the task should be called.
                let read = try await service.read(
                    data: data,
                    isPDF: isPDF,
                    taskTitle: taskTitle
                )

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

                isIngesting = false
                statusMessage = read.degradeMessage
                // Open the new ticket: on a clean read so the card can be seen,
                // and on a degraded one so the fields are right there.
                if let added = tickets.first(where: { $0.id == addedId }) {
                    selected = added
                }
            } catch {
                isIngesting = false
                errorMessage = error.localizedDescription
            }
        }
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
    let taskTitle: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()

                ScrollView {
                    // The task already exists here, so nothing is ever pending.
                    TaskTicketSection(
                        todoId: todoId,
                        taskTitle: taskTitle,
                        pending: .constant([])
                    )
                    .padding(Space.lg)
                }
            }
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

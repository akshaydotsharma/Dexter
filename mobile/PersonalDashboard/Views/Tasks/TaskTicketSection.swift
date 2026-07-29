import SwiftUI
#if os(iOS)
// For the camera-availability gate on the add menu.
import UIKit
#endif

/// Ticket attachments for a task, shown as a stack of wallet cards inside the
/// task editor with an add button (#399).
///
/// Owns its own reads and writes through `TaskTicketService` rather than routing
/// them through `TasksViewModel`, for the reason `NoteImageStrip` does the same
/// (#395): attachments are scoped to the one task on screen, while the view
/// model's cached `todos` array is about the index.
///
/// Cards are stacked vertically rather than in a horizontal strip, because a
/// wallet card is a portrait object and the point of the feature is that it is
/// legible at a glance.
struct TaskTicketSection: View {
    let todoId: UUID
    let taskTitle: String

    @State private var tickets: [TaskTicket] = []
    @State private var selected: TaskTicket?
    @State private var isIngesting = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    #if os(iOS)
    @State private var showingCamera = false
    #endif
    @State private var showingPhotoLibrary = false
    @State private var showingPDFPicker = false

    private let service = TaskTicketService()

    private var accent: Color { Tokens.accent(for: .tasks) }

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
                addMenu
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
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.danger)
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $selected) { ticket in
            TaskTicketDetailSheet(
                ticket: ticket,
                taskTitle: taskTitle,
                onChange: reload
            )
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { data in
                ingest(data: data, isPDF: false)
            }
        }
        #endif
        .photoLibraryPicker(isPresented: $showingPhotoLibrary) { data in
            ingest(data: data, isPDF: false)
        }
        .pdfPicker(isPresented: $showingPDFPicker) { data, _ in
            ingest(data: data, isPDF: true)
        }
    }

    // MARK: - Pieces

    private var addMenu: some View {
        Menu {
            #if os(iOS)
            // Same gate the trip ticket menu uses: a simulator has no camera and
            // the row would otherwise present an empty picker.
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    Haptics.light()
                    showingCamera = true
                } label: {
                    Label("Scan with camera", systemImage: "camera")
                }
            }
            #endif
            Button {
                Haptics.light()
                showingPhotoLibrary = true
            } label: {
                Label("Choose a photo", systemImage: "photo.on.rectangle")
            }
            Button {
                Haptics.light()
                showingPDFPicker = true
            } label: {
                Label("Choose a PDF", systemImage: "doc.richtext")
            }
        } label: {
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
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isIngesting)
        .accessibilityLabel("Add a ticket to this task")
    }

    private var emptyHint: some View {
        Text("Attach a ticket, pass or booking confirmation. Dexter reads the details off it and gives you a card you can scan at the door.")
            .font(.edCaption)
            .foregroundStyle(Tokens.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
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
        do {
            tickets = try service.list(todoId: todoId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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
                let result = try await service.add(
                    todoId: todoId,
                    taskTitle: taskTitle,
                    data: data,
                    isPDF: isPDF
                )
                isIngesting = false
                reload()
                statusMessage = result.message
                // Open the new ticket: on a clean read so the card can be seen,
                // and on a degraded one so the fields are right there.
                if let added = tickets.first(where: { $0.id == result.ticketUUID }) {
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
                    TaskTicketSection(todoId: todoId, taskTitle: taskTitle)
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
    }
}

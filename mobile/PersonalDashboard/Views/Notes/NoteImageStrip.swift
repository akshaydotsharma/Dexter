import SwiftUI
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

/// Image attachments for a note, shown as a horizontal strip beneath the body
/// with an add button (#395).
///
/// Owns its own reads and writes through `NoteImageService` rather than routing
/// them through `NotesViewModel`: attachments are scoped to the one note on
/// screen, and the view model's cached `notes` array is about the index.
struct NoteImageStrip: View {
    let noteId: UUID
    /// Called after any change so the enclosing detail view can refresh the
    /// note's relative-time subtitle, which moves when attachments change.
    var onChange: () -> Void = {}

    @State private var images: [NoteImage] = []
    @State private var viewing: NoteImage?
    @State private var errorMessage: String?
    @State private var isAdding = false
    @State private var showPicker = false
    #if os(iOS)
    @State private var pickerSelection: [PhotosPickerItem] = []
    #endif

    private let service = NoteImageService()
    private let tileHeight: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header

            if images.isEmpty {
                emptyRow
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.sm) {
                        ForEach(images) { image in
                            tile(for: image)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: noteId) { reload() }
        // Picks up out-of-band writes (a data import, a sync apply) the same way
        // the other note surfaces do.
        .onReceive(NotificationCenter.default.publisher(for: .localStoreDidChange)) { _ in
            reload()
        }
        #if os(iOS)
        .photosPicker(
            isPresented: $showPicker,
            selection: $pickerSelection,
            maxSelectionCount: 10,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: pickerSelection) { _, items in
            guard !items.isEmpty else { return }
            // Clear immediately so re-picking the same photo still fires.
            pickerSelection = []
            Task { await addFromPhotos(items) }
        }
        #else
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { await addFromFiles(urls) }
        }
        #endif
        .sheet(item: $viewing) { image in
            NoteImageViewer(image: image, fileURL: service.fileURL(for: image))
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: Space.xs) {
            Text(images.isEmpty ? "Images" : "Images · \(images.count)")
                .eyebrow()
            Spacer()
            if isAdding {
                ProgressView()
                    .controlSize(.small)
                    .tint(Tokens.muted)
            }
            Button {
                errorMessage = nil
                showPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 13, weight: .regular))
                    Text("Add")
                        .font(.edFootnote)
                }
                .foregroundStyle(Tokens.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAdding)
            .help("Attach images to this note")
        }
    }

    private var emptyRow: some View {
        Button {
            errorMessage = nil
            showPicker = true
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Tokens.mutedSoft)
                Text("No images yet. Add one.")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                Spacer()
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity)
            .background(Tokens.paper2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAdding)
    }

    @ViewBuilder
    private func tile(for image: NoteImage) -> some View {
        let width = tileHeight * CGFloat(image.aspectRatio ?? 1)
        Group {
            if let url = service.fileURL(for: image),
               let platformImage = PlatformImage(contentsOfFile: url.path) {
                Image(platformImage: platformImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // The row exists but its bytes don't: synced from the other
                // device, or lost to a reinstall. Say which, rather than
                // rendering a blank tile that reads as a bug.
                missingTile
            }
        }
        .frame(width: max(width, tileHeight * 0.6), height: tileHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
        .contentShape(Rectangle())
        .onTapGesture { viewing = image }
        .contextMenu {
            Button(role: .destructive) {
                delete(image)
            } label: {
                Label("Remove image", systemImage: "trash")
            }
        }
        .accessibilityLabel("Note image")
    }

    private var missingTile: some View {
        VStack(spacing: Space.xs) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Tokens.mutedSoft)
            Text("On your other device")
                .font(.edCaption)
                .foregroundStyle(Tokens.mutedSoft)
                .multilineTextAlignment(.center)
        }
        .padding(Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.paper2)
    }

    // MARK: - Actions

    private func reload() {
        images = (try? service.list(noteId: noteId)) ?? []
    }

    private func delete(_ image: NoteImage) {
        do {
            try service.delete(image)
            reload()
            onChange()
        } catch {
            errorMessage = "Couldn't remove that image: \(error.localizedDescription)"
        }
    }

    /// Add a batch, reporting per-image failures without abandoning the rest:
    /// one unreadable photo in a ten-photo pick shouldn't lose the other nine.
    private func add(_ payloads: [Data]) async {
        guard !payloads.isEmpty else { return }
        isAdding = true
        var failures = 0
        for data in payloads {
            do {
                try await service.add(noteId: noteId, imageData: data)
            } catch {
                failures += 1
            }
        }
        isAdding = false
        reload()
        onChange()
        if failures > 0 {
            errorMessage = failures == payloads.count
                ? "Couldn't add \(failures == 1 ? "that image" : "those images")."
                : "Added \(payloads.count - failures), but \(failures) couldn't be read."
        }
    }

    #if os(iOS)
    private func addFromPhotos(_ items: [PhotosPickerItem]) async {
        isAdding = true
        var payloads: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                payloads.append(data)
            }
        }
        isAdding = false
        await add(payloads)
    }
    #else
    private func addFromFiles(_ urls: [URL]) async {
        var payloads: [Data] = []
        for url in urls {
            // The open panel hands back a security-scoped URL; without the
            // access bracket the read fails for anything outside the app's own
            // container even with the sandbox off.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                payloads.append(data)
            }
        }
        await add(payloads)
    }
    #endif
}

// MARK: - Full-size viewer

/// Full-size view of one attachment. Zoomable on iOS via the existing ticket
/// viewer's approach; a plain scaled image on macOS where the window resizes.
private struct NoteImageViewer: View {
    let image: NoteImage
    let fileURL: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                if let fileURL, let platformImage = PlatformImage(contentsOfFile: fileURL.path) {
                    Image(platformImage: platformImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(Space.md)
                } else {
                    VStack(spacing: Space.sm) {
                        Image(systemName: "icloud.slash")
                            .font(.system(size: 32, weight: .regular))
                            .foregroundStyle(Tokens.mutedSoft)
                        Text("This image is on your other device")
                            .font(.edBody)
                            .foregroundStyle(Tokens.muted)
                        Text("Sync moves the note but not its pictures. Bring them across with Export & import.")
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.mutedSoft)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Space.xl)
                    }
                }
            }
            .navigationTitle("Image")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }
}


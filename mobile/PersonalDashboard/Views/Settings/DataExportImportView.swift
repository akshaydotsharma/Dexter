import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Sheet that hosts export + import in a single surface. Two rows on the
/// landing page; tapping one drives the corresponding flow.
///
/// Export is non-destructive (just builds a file and hands it to the share
/// sheet), so no confirmation gate. Import goes through a preview screen so
/// the user can see what will change before committing, but no
/// type-to-confirm guard — merge by UUID is non-destructive by design.
struct DataExportImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private enum Phase {
        case idle
        case exporting
        case shareReady(URL)
        case importing
        case importPreview(DataImportService.Preview)
        case importCommitting(DataImportService.Preview)
        case importSucceeded(newRowCount: Int)
    }

    @State private var phase: Phase = .idle
    @State private var errorMessage: String? = nil
    @State private var showFileImporter: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                content
            }
            .navigationTitle(navigationTitle)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if showsBackButton {
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                phase = .idle
                                errorMessage = nil
                            }
                        } label: {
                            HStack(spacing: Space.xxs) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                        }
                        .foregroundStyle(Tokens.muted)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                        .disabled(isBusy)
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            handlePicked(result: result)
        }
    }

    private var navigationTitle: String {
        switch phase {
        case .importPreview, .importCommitting: return "Import preview"
        case .importSucceeded:                  return "Import complete"
        default:                                 return "Export & import"
        }
    }

    private var showsBackButton: Bool {
        switch phase {
        case .importPreview, .importSucceeded: return true
        default:                                return false
        }
    }

    private var isBusy: Bool {
        switch phase {
        case .exporting, .importing, .importCommitting: return true
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .exporting, .shareReady, .importing:
            idleScreen
        case .importPreview(let preview):
            previewScreen(preview: preview, isCommitting: false)
        case .importCommitting(let preview):
            previewScreen(preview: preview, isCommitting: true)
        case .importSucceeded(let count):
            successScreen(newRowCount: count)
        }
    }

    // MARK: - Idle (landing) screen

    private var idleScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text("Save a snapshot of every task, note, list, itinerary, expense, and vocab word on this device. Restore it later on a new install, or seed another phone.")
                    .font(.edBody)
                    .foregroundStyle(Tokens.muted)
                    .padding(.horizontal, Space.xs)

                DataActionsCard {
                    DataActionRow(
                        icon: "arrow.up.doc",
                        label: "Export all data",
                        sublabel: "Save a .zip you can share or back up.",
                        trailingState: exportTrailing,
                        disabled: isBusy
                    ) {
                        Task { await performExport() }
                    }

                    Rectangle()
                        .fill(Tokens.divider)
                        .frame(height: 0.5)
                        .padding(.leading, Space.lg)

                    DataActionRow(
                        icon: "arrow.down.doc",
                        label: "Import data",
                        sublabel: "Merge a Dexter export into this device.",
                        trailingState: importTrailing,
                        disabled: isBusy
                    ) {
                        showFileImporter = true
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.md)
                        .background(Tokens.dangerSoft, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }

                Text("Importing only adds rows whose IDs aren't already on this device. It never overwrites anything you have here.")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.mutedSoft)
                    .padding(.horizontal, Space.xs)

                Spacer(minLength: Space.xl)
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, 96)
        }
    }

    private var exportTrailing: DataActionRow.TrailingState {
        switch phase {
        case .exporting: return .progress
        default:         return .chevron
        }
    }

    private var importTrailing: DataActionRow.TrailingState {
        switch phase {
        case .importing: return .progress
        default:         return .chevron
        }
    }

    // MARK: - Import preview screen

    private func previewScreen(preview: DataImportService.Preview, isCommitting: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("From")
                        .eyebrow()
                    Text(preview.archiveURL.lastPathComponent)
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("Exported \(Self.relativeDate(preview.manifest.exportedAt)) · app v\(preview.manifest.appVersion)")
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.lg)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                .paperBorder()

                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("What will be added")
                        .eyebrow()
                        .padding(.horizontal, Space.xs)

                    VStack(spacing: 0) {
                        let entities = DataImportService.Entity.allCases.enumerated().map { ($0, $1) }
                        ForEach(entities, id: \.1.id) { idx, entity in
                            PreviewRow(
                                entity: entity,
                                counts: preview.counts[entity] ?? .zero
                            )
                            if idx < entities.count - 1 {
                                Rectangle()
                                    .fill(Tokens.divider)
                                    .frame(height: 0.5)
                                    .padding(.leading, Space.lg)
                            }
                        }
                    }
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                    .paperBorder()
                }

                if !preview.hasAnythingToImport {
                    Text("Everything in this archive is already on this device. Nothing new to add.")
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.muted)
                        .padding(.horizontal, Space.xs)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.md)
                        .background(Tokens.dangerSoft, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }

                Button(action: { Task { await performImportCommit(preview: preview) } }) {
                    HStack(spacing: Space.sm) {
                        if isCommitting {
                            ProgressView().tint(.white)
                        }
                        Text(isCommitting ? "Importing…" : commitButtonLabel(preview: preview))
                            .font(.edBodyMedium)
                    }
                    .foregroundStyle(canCommit(preview: preview) ? Color.white : Tokens.mutedSoft)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        canCommit(preview: preview) ? Tokens.ink : Tokens.paper2,
                        in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canCommit(preview: preview) || isCommitting)

                Spacer(minLength: Space.xl)
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, 96)
        }
    }

    private func canCommit(preview: DataImportService.Preview) -> Bool {
        preview.hasAnythingToImport
    }

    private func commitButtonLabel(preview: DataImportService.Preview) -> String {
        let count = preview.totalNew
        if count == 0 { return "Nothing to import" }
        if count == 1 { return "Import 1 new row" }
        return "Import \(count) new rows"
    }

    // MARK: - Success screen

    private func successScreen(newRowCount: Int) -> some View {
        VStack(spacing: Space.lg) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(Tokens.success)
            VStack(spacing: Space.xs) {
                Text(newRowCount == 0 ? "Nothing new to add" : "Import complete")
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                Text(successDetail(newRowCount: newRowCount))
                    .font(.edBody)
                    .foregroundStyle(Tokens.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Space.xl)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.edBodyMedium)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Tokens.ink, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.xl)
        }
    }

    private func successDetail(newRowCount: Int) -> String {
        if newRowCount == 0 {
            return "Every row in that archive was already on this device."
        }
        if newRowCount == 1 {
            return "Added 1 new row. Existing rows were left untouched."
        }
        return "Added \(newRowCount) new rows. Existing rows were left untouched."
    }

    // MARK: - Actions

    private func performExport() async {
        errorMessage = nil
        phase = .exporting
        let service = DataExportService(modelContext: modelContext)
        do {
            let url = try service.export()
            #if os(iOS)
            phase = .shareReady(url)
            await presentShareSheet(for: url)
            // Hand back to idle once the share sheet dismisses. The tmp
            // file stays on disk for the OS to clean up (sharing copies
            // it into Files / Mail / etc).
            phase = .idle
            #else
            // macOS has no share sheet; let the user pick a save location and
            // copy the exported archive there (issue #281).
            phase = .idle
            saveExportedArchive(at: url)
            #endif
        } catch {
            phase = .idle
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func handlePicked(result: Result<[URL], Error>) {
        errorMessage = nil
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await performImportPreview(url: url) }
        }
    }

    private func performImportPreview(url: URL) async {
        phase = .importing
        let service = DataImportService(modelContext: modelContext)
        do {
            let preview = try service.preview(url: url)
            phase = .importPreview(preview)
        } catch {
            phase = .idle
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func performImportCommit(preview: DataImportService.Preview) async {
        errorMessage = nil
        phase = .importCommitting(preview)
        let service = DataImportService(modelContext: modelContext)
        do {
            try service.commit(preview: preview)
            phase = .importSucceeded(newRowCount: preview.totalNew)
        } catch {
            phase = .importPreview(preview)
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    #if os(iOS)
    @MainActor
    private func presentShareSheet(for url: URL) async {
        guard let topController = topMostViewController() else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // The iOS Share sheet doesn't surface a "did dismiss" callback we
        // can await; use a continuation tied to the completion handler.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            activity.completionWithItemsHandler = { _, _, _, _ in
                continuation.resume()
            }
            // iPad popover anchor — anchored to the topmost view's center
            // so the popover has somewhere to attach.
            if let popover = activity.popoverPresentationController {
                popover.sourceView = topController.view
                popover.sourceRect = CGRect(
                    x: topController.view.bounds.midX,
                    y: topController.view.bounds.midY,
                    width: 0,
                    height: 0
                )
                popover.permittedArrowDirections = []
            }
            topController.present(activity, animated: true)
        }
    }

    private func topMostViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let root = scene?.keyWindow?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
    #endif

    #if os(macOS)
    /// macOS export: present an `NSSavePanel` and copy the freshly built
    /// archive to the chosen location. There is no share sheet on macOS, so the
    /// user saves the `.zip` directly (issue #281).
    @MainActor
    private func saveExportedArchive(at url: URL) {
        let panel = NSSavePanel()
        panel.title = "Save Dexter export"
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            errorMessage = "Couldn't save export: \(error.localizedDescription)"
        }
    }
    #endif

    // MARK: - Helpers

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Sub-views

private struct DataActionsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .paperBorder()
    }
}

private struct DataActionRow: View {
    enum TrailingState {
        case chevron
        case progress
    }

    let icon: String
    let label: String
    let sublabel: String
    let trailingState: TrailingState
    let disabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(disabled ? Tokens.mutedSoft : Tokens.ink)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.edBody)
                        .foregroundStyle(disabled ? Tokens.mutedSoft : Tokens.ink)
                    Text(sublabel)
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(2)
                }

                Spacer(minLength: Space.md)

                switch trailingState {
                case .chevron:
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Tokens.mutedSoft)
                case .progress:
                    ProgressView().tint(Tokens.muted)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct PreviewRow: View {
    let entity: DataImportService.Entity
    let counts: DataImportService.EntityCounts

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: entity.icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Tokens.muted)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(entity.label)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                Text(detailLine)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
            }

            Spacer(minLength: Space.md)

            HStack(spacing: Space.xs) {
                Text("+\(counts.new)")
                    .font(.edBodyMedium)
                    .monospacedDigit()
                    .foregroundStyle(counts.new > 0 ? Tokens.success : Tokens.mutedSoft)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    private var detailLine: String {
        if counts.total == 0 { return "0 in file" }
        return "\(counts.total) in file · \(counts.skipped) already here"
    }
}

#if os(iOS)
private extension UIWindowScene {
    var keyWindow: UIWindow? {
        windows.first { $0.isKeyWindow } ?? windows.first
    }
}
#endif

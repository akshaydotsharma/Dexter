import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Opt-in automatic local backup. The user picks a folder (typically in
/// iCloud Drive); we persist a security-scoped bookmark and write a single
/// rolling `Dexter-Backup.zip` into it on a best-effort cadence. iOS syncs
/// that folder to iCloud transparently, so this works on free personal-team
/// signing with no iCloud entitlement.
///
/// Restore reuses the existing import flow (`DataExportImportView`), which
/// merges a `.zip` by UUID and never overwrites anything already here.
struct BackupSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @AppStorage(BackupSettings.Key.enabled)   private var enabled: Bool = false
    @AppStorage(BackupSettings.Key.frequency) private var frequencyRaw: String = BackupFrequency.daily.rawValue
    @AppStorage(BackupSettings.Key.folderName) private var folderName: String = ""

    @State private var showFolderPicker: Bool = false
    @State private var showRestore: Bool = false
    @State private var isBackingUp: Bool = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil

    /// Mirror of `BackupSettings.lastBackupAt`, surfaced as state so the
    /// status line refreshes after a manual "Back up now".
    @State private var lastBackupAt: Date? = BackupSettings.lastBackupAt
    @State private var lastFileName: String? = BackupSettings.lastFileName

    private var frequency: Binding<BackupFrequency> {
        Binding(
            get: { BackupFrequency(rawValue: frequencyRaw) ?? .daily },
            set: { frequencyRaw = $0.rawValue }
        )
    }

    private var hasFolder: Bool { !folderName.isEmpty && BackupSettings.folderBookmark != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("Backup")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                        .disabled(isBackingUp)
                }
            }
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderPicked(result)
        }
        .sheet(isPresented: $showRestore) {
            DataExportImportView()
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text("Keep a copy of everything on this device in a folder you choose. Point it at iCloud Drive and your backup rides along to the cloud automatically.")
                    .font(.edBody)
                    .foregroundStyle(Tokens.muted)
                    .padding(.horizontal, Space.xs)

                automaticCard

                if enabled {
                    actionsCard
                }

                if let errorMessage {
                    feedback(errorMessage, tint: Tokens.danger, background: Tokens.dangerSoft)
                }
                if let successMessage {
                    feedback(successMessage, tint: Tokens.success, background: Tokens.successSoft)
                }

                restoreCard

                Text("Daily and weekly backups are best-effort. iOS won't reliably wake a closed app on a timer, so a scheduled backup runs the next time you open Dexter after that interval has passed.")
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

    // MARK: - Automatic backup card

    private var automaticCard: some View {
        VStack(spacing: 0) {
            // Toggle row
            HStack(spacing: Space.md) {
                Image(systemName: "arrow.clockwise.icloud")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Tokens.ink)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic iCloud backup")
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                    Text("Write a snapshot to your chosen folder.")
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(2)
                }

                Spacer(minLength: Space.md)

                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .tint(Tokens.accentItineraries)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)

            if enabled {
                divider

                // Folder row
                Button {
                    showFolderPicker = true
                } label: {
                    HStack(spacing: Space.md) {
                        Image(systemName: "folder")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Tokens.ink)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Backup location")
                                .font(.edBody)
                                .foregroundStyle(Tokens.ink)
                            Text(hasFolder ? folderName : "Choose a folder")
                                .font(.edFootnote)
                                .foregroundStyle(hasFolder ? Tokens.muted : Tokens.mutedSoft)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: Space.md)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Tokens.mutedSoft)
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                divider

                // Frequency row
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Frequency")
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                    FrequencyPicker(value: frequency)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
            }
        }
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .paperBorder()
    }

    // MARK: - Actions card (back up now + status)

    private var actionsCard: some View {
        VStack(spacing: 0) {
            Button {
                Task { await backUpNow() }
            } label: {
                HStack(spacing: Space.md) {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(hasFolder ? Tokens.ink : Tokens.mutedSoft)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Back up now")
                            .font(.edBody)
                            .foregroundStyle(hasFolder ? Tokens.ink : Tokens.mutedSoft)
                        Text(statusLine)
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: Space.md)

                    if isBackingUp {
                        ProgressView().tint(Tokens.muted)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Tokens.mutedSoft)
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasFolder || isBackingUp)
        }
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .paperBorder()
    }

    // MARK: - Restore card

    private var restoreCard: some View {
        VStack(spacing: 0) {
            Button {
                showRestore = true
            } label: {
                HStack(spacing: Space.md) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Tokens.ink)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restore from backup…")
                            .font(.edBody)
                            .foregroundStyle(Tokens.ink)
                        Text("Merge a .zip back in. Nothing already here is overwritten.")
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.muted)
                            .lineLimit(2)
                    }

                    Spacer(minLength: Space.md)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Tokens.mutedSoft)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .paperBorder()
    }

    // MARK: - Feedback

    private func feedback(_ message: String, tint: Color, background: Color) -> some View {
        Text(message)
            .font(.edFootnote)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.md)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    private var statusLine: String {
        guard let lastBackupAt else { return "Not backed up yet." }
        let when = Self.relativeDate(lastBackupAt)
        if let lastFileName, !lastFileName.isEmpty {
            return "Last backed up \(when) · \(lastFileName)"
        }
        return "Last backed up \(when)"
    }

    // MARK: - Actions

    private func handleFolderPicked(_ result: Result<[URL], Error>) {
        errorMessage = nil
        successMessage = nil
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let service = BackupService(modelContext: modelContext)
            do {
                let name = try service.saveFolder(url)
                folderName = name
                Haptics.light()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func backUpNow() async {
        errorMessage = nil
        successMessage = nil
        isBackingUp = true
        defer { isBackingUp = false }

        let service = BackupService(modelContext: modelContext)
        do {
            try service.runBackupIfDue(force: true)
            lastBackupAt = BackupSettings.lastBackupAt
            lastFileName = BackupSettings.lastFileName
            successMessage = "Backed up to \(folderName)."
            Haptics.light()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Haptics.destructive()
        }
    }

    // MARK: - Helpers

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Frequency picker

/// Segmented control matching the app's `ThemePicker` style: a pill track
/// with the selected option lifted onto a surface chip.
private struct FrequencyPicker: View {
    @Binding var value: BackupFrequency

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(BackupFrequency.allCases) { option in
                FrequencyOption(
                    option: option,
                    isSelected: value == option,
                    onTap: {
                        withAnimation(.easeOut(duration: 0.15)) { value = option }
                    }
                )
            }
        }
        .padding(Space.xs)
        .background(Tokens.paper2, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }
}

private struct FrequencyOption: View {
    let option: BackupFrequency
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(option.label)
                .font(.edFootnote)
                .foregroundStyle(isSelected ? Tokens.ink : Tokens.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                .fill(Tokens.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                        .stroke(Tokens.border, lineWidth: 0.5)
                                )
                        }
                    }
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared divider

private extension BackupSettingsView {
    var divider: some View {
        Rectangle()
            .fill(Tokens.divider)
            .frame(height: 0.5)
            .padding(.leading, Space.lg)
    }
}

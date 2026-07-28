import SwiftUI

struct SettingsView: View {
    @Bindable var router: AppRouter
    @Binding var schemePref: ColorSchemePref

    @State private var showingResetData: Bool = false
    @State private var showingDataTransfer: Bool = false
    // Receipts inbox is iOS-only (backed by BackgroundTasks email ingest), so
    // this flag and its row/sheet are compiled out on macOS (issue #281).
    #if os(iOS)
    @State private var showingEmailInbox: Bool = false
    #endif
    @State private var showingParsedFiles: Bool = false
    @State private var showingBackup: Bool = false
    @State private var showingSync: Bool = false

    /// Currency all finances are DISPLAYED in (#220). SGD stays the canonical
    /// stored base — this is a display-only conversion applied at format time.
    /// Keyed to the same UserDefaults string `FinanceSettings` reads, so the
    /// picker and the money formatter stay in lockstep.
    @AppStorage(FinanceSettings.Key.displayCurrencyCode)
    private var displayCurrencyCode: String = "SGD"

    var body: some View {
        ZStack {
            Tokens.paper.canvasIgnoresSafeArea()
            rootContent
        }
        .activeSection(.settings)
        .macSectionChrome("Settings")
        .sheet(isPresented: $showingResetData) {
            ResetDataView()
        }
        .sheet(isPresented: $showingDataTransfer) {
            DataExportImportView()
        }
        #if os(iOS)
        .sheet(isPresented: $showingEmailInbox) {
            EmailInboxView()
        }
        #endif
        .sheet(isPresented: $showingParsedFiles) {
            ParsedFilesView()
        }
        .sheet(isPresented: $showingBackup) {
            BackupSettingsView()
        }
        // iOS only: on macOS Sync is a popover anchored to its row (#351), so
        // declaring the sheet here too would present it twice.
        #if os(iOS)
        .sheet(isPresented: $showingSync) {
            SyncStatusView()
        }
        #endif
    }

    // MARK: - Root

    private var rootContent: some View {
        VStack(spacing: 0) {
            // iOS in-view top bar; macOS uses the native window toolbar
            // via `.macSectionChrome` on the body (issue #283).
            #if os(iOS)
            TopBar(
                title: "Settings",
                onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } }
            )
            #endif

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    appearanceSection
                    aiSection
                    financeSection
                    automationSection
                    dataSection
                    aboutSection
                    footer
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.lg)
                .padding(.bottom, 96)
            }
        }
    }

    // MARK: - Sections

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance") {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Theme")
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)

                ThemePicker(value: $schemePref)
            }
            .padding(Space.lg)
        }
    }

    /// Anthropic key entry (#337). The build-time key is a property of the
    /// build, so a regenerated Xcode project or a fresh install can arrive
    /// without one and every AI surface refuses. This is the source the user
    /// controls, and it takes precedence over the build's own value.
    private var aiSection: some View {
        SettingsSection(title: "AI") {
            AnthropicKeyRow()
        }
    }

    private var financeSection: some View {
        SettingsSection(title: "Finance") {
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default currency")
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                    Text("Show all finances converted to this currency")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                }

                Spacer(minLength: Space.md)

                Picker("Default currency", selection: $displayCurrencyCode) {
                    ForEach(SupportedCurrency.all, id: \.self) { code in
                        Text(code).tag(code)
                    }
                }
                .pickerStyle(.menu)
                .tint(Tokens.accentFinance)
                .labelsHidden()
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            // Re-warm the FX factor whenever the choice changes so totals
            // reflect the new currency on the next Finance visit (#220).
            .onChange(of: displayCurrencyCode) { _, _ in
                Task { await FXService.default().refreshDisplayRate() }
            }
        }
    }

    private var automationSection: some View {
        SettingsSection(title: "Automation") {
            VStack(spacing: 0) {
                // Receipts inbox is iOS-only (BackgroundTasks email ingest);
                // macOS shows only the parsed-files history row (issue #281).
                #if os(iOS)
                Button {
                    showingEmailInbox = true
                } label: {
                    automationRow(
                        title: "Receipts inbox",
                        subtitle: "Connect the inbox that auto-adds from forwarded booking emails"
                    )
                }
                .buttonStyle(.plain)

                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)
                    .padding(.leading, Space.lg)
                #endif

                Button {
                    showingParsedFiles = true
                } label: {
                    automationRow(
                        title: "Parsed files & imports",
                        subtitle: "History of everything read from statements and forwarded emails"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func automationRow(title: String, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                Text(subtitle)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
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

    private var dataSection: some View {
        SettingsSection(title: "Data") {
            VStack(spacing: 0) {
                Button {
                    showingDataTransfer = true
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                        Text("Export & import…")
                            .font(.edBody)
                            .foregroundStyle(Tokens.ink)
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

                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)
                    .padding(.leading, Space.lg)

                Button {
                    showingBackup = true
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                        Text("Backup…")
                            .font(.edBody)
                            .foregroundStyle(Tokens.ink)
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

                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)
                    .padding(.leading, Space.lg)

                Button {
                    showingSync = true
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                        Text("Sync…")
                            .font(.edBody)
                            .foregroundStyle(Tokens.ink)
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
                // macOS: a popover hanging off the row that opened it (#351), so
                // it reads as local to Settings. A `.sheet` here rendered as a
                // small centred window that clipped every row away, which is the
                // same trap #341 hit with the Finance filters. iOS keeps the
                // parent `.sheet` declared on the body.
                #if os(macOS)
                .popover(isPresented: $showingSync, arrowEdge: .bottom) {
                    SyncStatusView()
                }
                #endif

                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)
                    .padding(.leading, Space.lg)

                Button {
                    showingResetData = true
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                        Text("Reset data…")
                            .font(.edBody)
                            .foregroundStyle(Tokens.danger)
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
        }
    }

    private var aboutSection: some View {
        SettingsSection(title: "About") {
            VStack(spacing: 0) {
                SettingsRow(label: "Version", value: shortVersion)
                SettingsDivider()
                SettingsRow(label: "Build", value: buildNumber)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: Space.xs) {
            Text("Dexter")
                .font(.edTitle)
                .foregroundStyle(Tokens.ink)
            Text("A small place to think and do.")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.xl)
    }

    // MARK: - Bundle helpers

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

// MARK: - Sub-views

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).eyebrow()
                .padding(.horizontal, Space.xs)

            content
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                .paperBorder()
        }
    }
}

/// Anthropic API key entry (#337): a status line, a secure field, and Save /
/// Remove. Nothing here ever shows the stored key in full — the status line
/// carries a masked preview so the user can tell which key is in effect.
private struct AnthropicKeyRow: View {
    @State private var draft: String = ""
    @State private var source: UserAPIKeys.Source = UserAPIKeys.anthropicSource
    @State private var maskedKey: String? = UserAPIKeys.anthropic.map(UserAPIKeys.masked)
    @State private var writeFailed: Bool = false
    @FocusState private var fieldFocused: Bool

    private var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Anthropic API key")
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                    Text(statusLine)
                        .font(.edCaption)
                        .foregroundStyle(source == .none ? Tokens.danger : Tokens.muted)
                }
                Spacer(minLength: Space.md)
                if source == .keychain {
                    Button("Remove") { save(nil) }
                        .buttonStyle(.plain)
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.danger)
                }
            }

            HStack(spacing: Space.sm) {
                SecureField("sk-ant-…", text: $draft)
                    .paperFieldOnMac()
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .noAutocapitalization()
                    .autocorrectionDisabled(true)
                    .focused($fieldFocused)
                    .onSubmit { if canSave { save(draft) } }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .background(Tokens.paper2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .paperBorder(Tokens.border, radius: Radius.md)

                Button("Save") { save(draft) }
                    .buttonStyle(.plain)
                    .font(.edBodyMedium)
                    .foregroundStyle(canSave ? Tokens.accentTasks : Tokens.muted)
                    .disabled(!canSave)
            }

            Text(writeFailed
                 ? "Couldn't save the key to the Keychain."
                 : "Stored in the device Keychain and used for Chat, receipts, and statement import. It is never sent anywhere except Anthropic.")
                .font(.edCaption)
                .foregroundStyle(writeFailed ? Tokens.danger : Tokens.muted)
        }
        .padding(Space.lg)
    }

    private var statusLine: String {
        if let maskedKey, source == .keychain {
            return "\(source.label) · \(maskedKey)"
        }
        return source.label
    }

    private func save(_ value: String?) {
        let ok = UserAPIKeys.setAnthropic(value)
        writeFailed = !ok
        draft = ""
        fieldFocused = false
        source = UserAPIKeys.anthropicSource
        maskedKey = UserAPIKeys.anthropic.map(UserAPIKeys.masked)
    }
}

private struct SettingsRow: View {
    let label: String
    let value: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(label)
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)

            Spacer(minLength: Space.md)

            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Tokens.divider)
            .frame(height: 0.5)
            .padding(.leading, Space.lg)
    }
}

private struct ThemePicker: View {
    @Binding var value: ColorSchemePref

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(ColorSchemePref.allCases, id: \.self) { option in
                ThemePickerOption(
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

private struct ThemePickerOption: View {
    let option: ColorSchemePref
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Space.xs) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .regular))
                Text(label)
                    .font(.edFootnote)
            }
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

    private var icon: String {
        switch option {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    private var label: String {
        switch option {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

import SwiftUI
import SwiftData

/// Settings surface for the email-to-itinerary inbox (#143). Lets the user
/// enter and update the Gmail IMAP credentials (host / email / app password),
/// toggle the feature on, run a manual fetch, and review a recent log of
/// auto-added and skipped emails.
///
/// The app password is write-only from the UI's perspective: we show whether
/// one is stored, never the value. It is held in the Keychain via
/// `EmailInboxConfig`.
struct EmailInboxView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var host: String = ""
    @State private var port: String = ""
    @State private var email: String = ""
    @State private var appPassword: String = ""
    @State private var enabled: Bool = false
    @State private var hasStoredPassword: Bool = false

    @State private var isFetching = false
    @State private var fetchSummary: String?
    @State private var saveConfirmation = false
    @State private var selectedEntry: LocalEmailIngestLog?

    // Recent log, newest first.
    @Query(sort: \LocalEmailIngestLog.createdAt, order: .reverse)
    private var logEntries: [LocalEmailIngestLog]

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        intro
                        credentialsSection
                        actionsSection
                        logSection
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.lg)
                    .padding(.bottom, 64)
                }
            }
            .navigationTitle("Receipts inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(item: $selectedEntry) { entry in
                EmailIngestDetailView(entry: entry)
            }
        }
        .onAppear(perform: load)
    }

    // MARK: - Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Forward booking and reservation emails to your receipts inbox. Dexter reads them on-device, matches each one to an existing trip by date and destination, and adds the itinerary items automatically.")
                .font(.edSubheadline)
                .foregroundStyle(Tokens.inkSoft)
            Text("Use a Gmail app password, not your account password. Nothing is sent to a server: the password stays in the device Keychain and email is fetched directly over IMAP.")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
        }
    }

    private var credentialsSection: some View {
        Section(title: "Connection") {
            VStack(spacing: 0) {
                Toggle(isOn: $enabled) {
                    Text("Auto-add from forwarded emails")
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                }
                .tint(Tokens.accentItineraries)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)

                divider
                field(label: "IMAP host", text: $host, placeholder: EmailInboxCredentials.defaultHost, keyboard: .URL)
                divider
                field(label: "Port", text: $port, placeholder: "993", keyboard: .numberPad)
                divider
                field(label: "Email", text: $email, placeholder: EmailInboxCredentials.defaultEmail, keyboard: .emailAddress)
                divider
                passwordField
            }
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text("App password")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                Spacer()
                if hasStoredPassword {
                    Label("Stored", systemImage: "checkmark.circle.fill")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.success)
                }
            }
            SecureField(hasStoredPassword ? "Enter to replace" : "16-char app password", text: $appPassword)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
            if hasStoredPassword {
                Button("Remove stored password", role: .destructive) {
                    EmailInboxConfig.setPassword("")
                    appPassword = ""
                    hasStoredPassword = false
                }
                .font(.edCaption)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    private var actionsSection: some View {
        Section(title: "Fetch") {
            VStack(spacing: 0) {
                Button {
                    fetchNow()
                } label: {
                    HStack(spacing: Space.md) {
                        if isFetching {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 15))
                        }
                        Text(isFetching ? "Checking inbox…" : "Check inbox now")
                            .font(.edBody)
                        Spacer()
                    }
                    .foregroundStyle(EmailInboxConfig.isReady ? Tokens.ink : Tokens.mutedSoft)
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isFetching || !canFetch)

                divider

                Button {
                    fetchNow(ignoreProcessed: true)
                } label: {
                    HStack(spacing: Space.md) {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 15))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Re-scan (ignore processed)")
                                .font(.edBody)
                            Text("Re-run already-fetched emails through the latest parsing and matching")
                                .font(.edCaption)
                                .foregroundStyle(Tokens.muted)
                        }
                        Spacer()
                    }
                    .foregroundStyle(EmailInboxConfig.isReady ? Tokens.ink : Tokens.mutedSoft)
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isFetching || !canFetch)

                if let summary = fetchSummary {
                    divider
                    Text(summary)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.md)
                }
            }
        }
    }

    @ViewBuilder
    private var logSection: some View {
        Section(title: "Recent activity") {
            if logEntries.isEmpty {
                Text("No emails processed yet. Forward a hotel or flight confirmation to get started.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.lg)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(logEntries.prefix(10).enumerated()), id: \.element.clientUUID) { index, entry in
                        if index > 0 { divider }
                        logRow(entry)
                    }
                }
            }
        }
    }

    private func logRow(_ entry: LocalEmailIngestLog) -> some View {
        Button {
            selectedEntry = entry
        } label: {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: entry.outcomeEnum.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(color(for: entry.outcomeEnum))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.subject.isEmpty ? "(no subject)" : entry.subject)
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)
                        .lineLimit(1)
                    Text(entry.summary)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(2)
                    Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                }
                Spacer(minLength: Space.sm)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Tokens.mutedSoft)
                    .padding(.top, 2)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Building blocks

    private func field(label: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text(label)
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
            TextField(placeholder, text: text)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    private var divider: some View {
        Rectangle()
            .fill(Tokens.divider)
            .frame(height: 0.5)
            .padding(.leading, Space.lg)
    }

    private func color(for outcome: EmailIngestOutcome) -> Color {
        switch outcome {
        case .added:   return Tokens.success
        case .skipped: return Tokens.muted
        case .failed:  return Tokens.danger
        }
    }

    private var canFetch: Bool {
        enabled && (hasStoredPassword || !appPassword.isEmpty) && !email.isEmpty && !host.isEmpty
    }

    // MARK: - Actions

    private func load() {
        let s = EmailInboxConfig.settings
        host = s.host
        port = String(s.port)
        email = s.email
        enabled = EmailInboxConfig.isEnabled
        hasStoredPassword = EmailInboxConfig.hasPassword
        appPassword = ""
    }

    private func save() {
        var settings = EmailInboxConfig.settings
        settings.host = host.trimmingCharacters(in: .whitespaces)
        settings.port = Int(port) ?? EmailInboxCredentials.defaultPort
        settings.email = email.trimmingCharacters(in: .whitespaces)
        EmailInboxConfig.settings = settings

        let pw = appPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pw.isEmpty {
            EmailInboxConfig.setPassword(pw)
            hasStoredPassword = true
            appPassword = ""
        }
        EmailInboxConfig.isEnabled = enabled
        saveConfirmation = true
        // Schedule background work now that config may be ready.
        EmailIngestCoordinator.shared.scheduleBackgroundRefresh()
        dismiss()
    }

    private func fetchNow(ignoreProcessed: Bool = false) {
        // Persist current edits first so the fetch uses them.
        save0()
        isFetching = true
        fetchSummary = nil
        Task {
            await EmailIngestNotifications.requestAuthorizationIfNeeded()
            let result = await EmailIngestService().runFetchCycle(ignoreProcessed: ignoreProcessed)
            await MainActor.run {
                isFetching = false
                let prefix = ignoreProcessed ? "Re-scanned. " : ""
                // Re-scan can update existing items in place (#165); the
                // automatic cycle never does, so `updated` is 0 there.
                let updatedPart = result.updated > 0 ? "updated \(result.updated), " : ""
                fetchSummary = "\(prefix)Added \(result.added), \(updatedPart)skipped \(result.skipped), failed \(result.failed)."
            }
        }
    }

    /// Save without dismissing (used by Check-now so the fetch uses fresh creds).
    private func save0() {
        var settings = EmailInboxConfig.settings
        settings.host = host.trimmingCharacters(in: .whitespaces)
        settings.port = Int(port) ?? EmailInboxCredentials.defaultPort
        settings.email = email.trimmingCharacters(in: .whitespaces)
        EmailInboxConfig.settings = settings
        let pw = appPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pw.isEmpty {
            EmailInboxConfig.setPassword(pw)
            hasStoredPassword = true
            appPassword = ""
        }
        EmailInboxConfig.isEnabled = enabled
    }
}

/// Local section wrapper matching the SettingsView card look (eyebrow label +
/// rounded surface). Kept private to this file so it doesn't collide with the
/// one in SettingsView.
private struct Section<Content: View>: View {
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

/// Diagnostics detail for a single ingest-log entry (#143): the outcome, the
/// parsed body text the model actually received, and the trip-matching context
/// it was given. This is what lets us tell a parser miss ("just a signature")
/// apart from a real no-match, without needing the device console.
private struct EmailIngestDetailView: View {
    let entry: LocalEmailIngestLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        field("Outcome", entry.outcomeEnum.displayName)
                        field("Subject", entry.subject.isEmpty ? "(none)" : entry.subject)
                        if !entry.sender.isEmpty { field("From", entry.sender) }
                        field("Summary", entry.summary)
                        monospaceBlock("Parsed body the model received",
                                       entry.debugBody.isEmpty ? "(not recorded)" : entry.debugBody)
                        monospaceBlock("Trips the model could match against",
                                       entry.debugTripContext.isEmpty ? "(not recorded)" : entry.debugTripContext)
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle("Email detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).eyebrow()
            Text(value)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .textSelection(.enabled)
        }
    }

    private func monospaceBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).eyebrow()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Tokens.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.md)
                .background(Tokens.paper2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .textSelection(.enabled)
        }
    }
}

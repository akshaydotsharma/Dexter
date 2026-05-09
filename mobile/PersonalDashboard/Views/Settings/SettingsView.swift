import SwiftUI

struct SettingsView: View {
    @Bindable var router: AppRouter
    @Binding var schemePref: ColorSchemePref

    var body: some View {
        ZStack {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(
                    title: "Settings",
                    onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        appearanceSection
                        aboutSection
                        footer
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.lg)
                    .padding(.bottom, 96)
                }
            }
        }
        .activeSection(.settings)
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

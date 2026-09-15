import SwiftUI

/// 56pt top bar matching `TopBar.jsx`. Leading hamburger,
/// title in Calistoga 22, AS pip trailing.
///
/// `trailing` is an optional section-specific control that sits just left of the
/// AS pip — the Lists/Notes Archive button is the first user (#374). It defaults
/// to `EmptyView`, so every existing call site is unchanged and renders exactly
/// as before.
struct TopBar<Trailing: View>: View {
    var title: String?
    var onMenu: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Space.md) {
            Button(action: onMenu) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Tokens.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Open navigation")

            if let title, !title.isEmpty {
                Text(title)
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
            }

            Spacer()

            trailing()

            // Profile pip — paper coin, not a colored badge.
            Text("AS")
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
                .frame(width: 32, height: 32)
                .background(Tokens.paper2, in: Circle())
                .overlay(Circle().stroke(Tokens.border, lineWidth: 0.5))
                .accessibilityLabel("Akshay")
        }
        .padding(.horizontal, Space.md)
        .frame(height: 56)
        .background(
            Tokens.paper
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Tokens.divider)
                        .frame(height: 0.5)
                }
        )
    }
}

extension TopBar where Trailing == EmptyView {
    /// The plain two-argument form every section other than Lists and Notes uses.
    /// Without this, making `Trailing` generic would force all thirteen existing
    /// call sites to spell out an empty trailing closure (#374).
    init(title: String? = nil, onMenu: @escaping () -> Void) {
        self.title = title
        self.onMenu = onMenu
        self.trailing = { EmptyView() }
    }
}

/// A section-level icon button sized to match the top bar's hamburger, for use in
/// `TopBar`'s trailing slot (#374). Same 44pt touch target and ink glyph, so the
/// two ends of the bar read as a matched pair.
struct TopBarIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    /// An optional word beside the glyph, for a control that is also an
    /// INDICATOR (#567). Meals' date control is the first: a bare glyph while
    /// today is selected, and the day's name once another is, so the chrome
    /// always says which day the content below belongs to.
    ///
    /// Nil is the ordinary icon-only button every earlier caller gets, and its
    /// rendering is unchanged. When it is set the control grows sideways only:
    /// the height and the 44 pt minimum touch target stay, so a labelled control
    /// and a bare one still line up in the same bar.
    var label: String? = nil

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .regular))
                if let label {
                    Text(label)
                        .font(.edFootnote)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Tokens.ink)
            .padding(.horizontal, label == nil ? 0 : Space.sm)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

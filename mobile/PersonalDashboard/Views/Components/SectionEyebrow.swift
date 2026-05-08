import SwiftUI

func sectionEyebrow(_ title: String) -> some View {
    Text(title)
        .eyebrow()
        .textCase(nil)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.paper)
}

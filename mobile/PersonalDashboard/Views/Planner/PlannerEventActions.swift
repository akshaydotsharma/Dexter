import SwiftUI

// MARK: - Undo toast

struct PlannerToast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    /// The override the Undo button soft-deletes.
    let overrideID: String

    static func == (a: PlannerToast, b: PlannerToast) -> Bool { a.id == b.id }
}

struct PlannerToastView: View {
    let toast: PlannerToast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.edFootnote)
                .foregroundStyle(Tokens.paper)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Undo", action: onUndo)
                .buttonStyle(.plain)
                .font(.edFootnoteStrong)
                .foregroundStyle(Tokens.paper)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(Capsule().stroke(Tokens.paper.opacity(0.6), lineWidth: 1))
                .accessibilityIdentifier("planner.toast.undo")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Tokens.ink, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .shadowLg()
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
    }
}

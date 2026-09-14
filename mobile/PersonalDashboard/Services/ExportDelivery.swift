import Foundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Handing a file the app just wrote to the user, on both platforms (#528).
///
/// The two platforms answer the same question differently and always have:
/// iOS opens the share sheet, macOS opens an `NSSavePanel`. Both halves used to
/// live private inside `DataExportImportView`, which meant the second feature
/// that wanted to export something (the trip expense report) would have had to
/// copy them — including the iPad popover anchor and the overwrite handling,
/// which are the parts that are easy to get wrong and invisible when they are.
///
/// Callers pass a file URL and get one call. The `#if` lives here, once.
enum ExportDelivery {

    enum Failure: LocalizedError {
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let reason): return "Couldn't save the file: \(reason)"
            }
        }
    }

    /// Presents the file to the user and returns once they are done with it.
    ///
    /// - Parameters:
    ///   - url: the file to hand over. It stays on disk; sharing and saving
    ///     both copy it.
    ///   - contentTypes: macOS save-panel file types. Ignored on iOS.
    ///   - panelTitle: macOS save-panel title. Ignored on iOS.
    /// - Throws: `Failure.saveFailed` when the macOS copy fails. The iOS share
    ///   sheet reports its own errors and never throws.
    @MainActor
    static func deliver(
        fileAt url: URL,
        contentTypes: [UTType] = [],
        panelTitle: String
    ) async throws {
        #if os(iOS)
        await presentShareSheet(for: url)
        #elseif os(macOS)
        try saveWithPanel(source: url, contentTypes: contentTypes, title: panelTitle)
        #endif
    }

    #if os(iOS)
    @MainActor
    private static func presentShareSheet(for url: URL) async {
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

    @MainActor
    private static func topMostViewController() -> UIViewController? {
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
    /// macOS export: present an `NSSavePanel` and copy the file the app just
    /// built to the chosen location. There is no share sheet on macOS, so the
    /// user saves the file directly (issue #281).
    @MainActor
    private static func saveWithPanel(source: URL, contentTypes: [UTType], title: String) throws {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = source.lastPathComponent
        if !contentTypes.isEmpty { panel.allowedContentTypes = contentTypes }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        // Cancelling is not an error: the user changed their mind.
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw Failure.saveFailed(error.localizedDescription)
        }
    }
    #endif
}

import AppKit
import UniformTypeIdentifiers

/// Finder's Quick Action "Open in Edmund" on folders (right-click ▸ Quick
/// Actions, and the preview pane's button). An action extension
/// (`com.apple.ui-services`, whose principal class must be a view
/// controller) that shows nothing: it hands the folders to the containing
/// Edmund.app and finishes.
///
/// Through LaunchServices rather than anything of the app's own, so the
/// sandboxed app is granted the folder the way Finder's Open With grants it.
///
/// The `@objc` name is what `NSExtensionPrincipalClass` in the appex
/// Info.plist names.
@objc(EdmundOpenFolderAction)
final class OpenFolderAction: NSViewController {

    override func loadView() {
        view = NSView(frame: .zero)
    }

    /// `nonisolated`: the host calls this on an XPC reply queue, not the main
    /// thread, and the main-actor isolation this override would otherwise
    /// inherit from NSViewController traps there (`dispatch_assert_queue_fail`,
    /// the first live run's crash). Main is reached below, for the work that
    /// needs it.
    nonisolated override func beginRequest(with context: NSExtensionContext) {
        let providers = (context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let found = FoundURLs()
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { found.append(url) }
                group.leave()
            }
        }
        // The context isn't Sendable; it is touched again only once every
        // provider has answered, on the main queue.
        nonisolated(unsafe) let context = context
        group.notify(queue: .main) {
            if let app = Self.containingApp, !found.urls.isEmpty {
                NSWorkspace.shared.open(found.urls, withApplicationAt: app,
                                        configuration: NSWorkspace.OpenConfiguration())
            }
            context.completeRequest(returningItems: nil)
        }
    }

    /// Edmund.app, three levels above this appex
    /// (Edmund.app/Contents/PlugIns/EdmundOpenFolder.appex).
    nonisolated static var containingApp: URL? {
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }
}

/// The providers answer on their own queues.
private final class FoundURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [URL] = []
    func append(_ url: URL) { lock.withLock { collected.append(url) } }
    var urls: [URL] { lock.withLock { collected } }
}

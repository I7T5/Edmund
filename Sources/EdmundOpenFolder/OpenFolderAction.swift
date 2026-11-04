import AppKit
import os

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
        // Whatever type the item is registered under: Finder hands a folder
        // over as `public.folder`, not `public.file-url`, so asking only for
        // a file URL found nothing and the action silently did nothing.
        for provider in providers {
            guard let type = provider.registeredTypeIdentifiers.first else { continue }
            Self.log.info("attachment types: \(provider.registeredTypeIdentifiers, privacy: .public)")
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let url = Self.url(from: item) { found.append(url) }
                else { Self.log.error("no URL in \(type, privacy: .public): \(String(describing: error), privacy: .public)") }
                group.leave()
            }
        }
        // The context isn't Sendable; it is touched again only once every
        // provider has answered, on the main queue.
        nonisolated(unsafe) let context = context
        group.notify(queue: .main) {
            let urls = found.urls
            Self.log.info("opening \(urls.count) item(s) in \(Self.containingApp?.path ?? "nil", privacy: .public)")
            if let app = Self.containingApp, !urls.isEmpty {
                NSWorkspace.shared.open(urls, withApplicationAt: app,
                                        configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { Self.log.error("open failed: \(error, privacy: .public)") }
                }
            }
            context.completeRequest(returningItems: nil)
        }
    }

    private nonisolated static let log = Logger(subsystem: "com.i7t5.edmund.openfolder", category: "action")

    /// An item provider's payload as a file URL: a URL, or its data form.
    private nonisolated static func url(from item: NSSecureCoding?) -> URL? {
        switch item {
        case let url as URL: url
        case let data as Data: URL(dataRepresentation: data, relativeTo: nil)
        default: nil
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

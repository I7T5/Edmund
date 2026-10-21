import AppKit
import QuickLookThumbnailing
import EdmundCore
import os.log

private let thumbLog = Logger(subsystem: "com.i7t5.edmund.thumbnail", category: "thumbnail")

// MARK: - Quick Look thumbnail for Markdown
//
// Finder's preview column and large icons show a file's thumbnail, never a
// data-based preview, so without this extension a Markdown file shows the
// system's generic text icon there. `QuickLookPage.thumbnail` draws the page;
// below `QLThumbnailMinimumDimension` (Info.plist) Finder keeps the generic
// icon, since text this small isn't legible.
//
// The `@objc` name is what `NSExtensionPrincipalClass` in the appex Info.plist
// references; Swift's mangled name would not resolve.
@objc(EdmundThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        thumbLog.log("provideThumbnail: \(url.lastPathComponent, privacy: .public) max \(request.maximumSize.width, privacy: .public)x\(request.maximumSize.height, privacy: .public) @\(request.scale, privacy: .public)x")
        let markdown: String
        do { markdown = try String(contentsOf: url, encoding: .utf8) } catch { return handler(nil, error) }
        let maximumSize = request.maximumSize, scale = request.scale

        // The HTML importer behind the page runs on the main thread. The
        // request arrives on a background queue; `sync` keeps the handler on
        // the caller's thread, so nothing non-Sendable crosses an actor hop.
        func render() -> (CGSize, CGImage?) {
            MainActor.assumeIsolated {
                // The page's portrait shape, fit into the size Quick Look asked for.
                let page = QuickLookPage.thumbnailPageSize
                let fit = min(maximumSize.width / page.width, maximumSize.height / page.height)
                let size = CGSize(width: (page.width * fit).rounded(), height: (page.height * fit).rounded())
                let image = QuickLookPage.thumbnail(
                    markdown: markdown, baseURL: url.deletingLastPathComponent(),
                    pixelSize: CGSize(width: size.width * scale, height: size.height * scale))
                return (size, image)
            }
        }
        let (size, image) = Thread.isMainThread ? render() : DispatchQueue.main.sync(execute: render)
        thumbLog.log("drew \(image == nil ? "nothing" : "\(image!.width)x\(image!.height) px", privacy: .public)")
        guard let image else { return handler(nil, nil) }
        handler(QLThumbnailReply(contextSize: size) { ctx in
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
            return true
        }, nil)
    }
}

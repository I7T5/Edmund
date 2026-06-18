import AppKit

// MARK: - Image Rendering
//
// `![alt](path)` renders the referenced image inline when the cursor is outside
// the token, and shows the raw, editable markdown when the cursor is inside it
// (the `.image` branch of `styleBlock`). The image is drawn by a
// `FragmentOverlay` anchored on the leading `!` — the same mechanism math and
// list markers use — with the rest of the markdown hidden and the line height
// reserved for the picture.
//
// Resolution: absolute paths, `~`-paths, and `file:` URLs load directly;
// relative paths resolve against the document's directory. Remote (http(s))
// images are skipped for now — loading them synchronously would block the main
// thread — so they fall back to the alt text.

// Loaded images are cached by resolved absolute path so a recompose doesn't
// re-read them from disk. NSCache is internally thread-safe.
nonisolated(unsafe) private let imageCache = NSCache<NSString, NSImage>()

extension EditorTextView {

    /// Loads the image referenced by an `![alt](destination)` link, or nil if it
    /// can't be resolved/loaded (the caller then shows the raw alt text).
    func loadImage(destination: String) -> NSImage? {
        guard let url = resolveImageURL(destination) else { return nil }
        let key = url.path as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    /// Resolves a destination string to a local file URL. Returns nil for remote
    /// URLs (handled as a fallback) or when a relative path can't be anchored.
    private func resolveImageURL(_ destination: String) -> URL? {
        let dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return nil }

        if let url = URL(string: dest), let scheme = url.scheme {
            return scheme == "file" ? url : nil   // skip http(s)/data for now
        }
        if dest.hasPrefix("/") { return URL(fileURLWithPath: dest) }
        if dest.hasPrefix("~") {
            return URL(fileURLWithPath: (dest as NSString).expandingTildeInPath)
        }
        // Relative to the document's directory.
        if let docDir = document?.fileURL?.deletingLastPathComponent() {
            return docDir.appendingPathComponent(dest)
        }
        return nil
    }

    /// A `FragmentOverlay` for the image, scaled down to fit the text width while
    /// keeping its aspect ratio. `bounds.minY == 0` sits the image bottom on the
    /// text baseline (the reserved line height makes room above it).
    func imageOverlay(destination: String) -> FragmentOverlay? {
        guard let image = loadImage(destination: destination) else { return nil }
        var size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let maxWidth = availableContentWidth
        if maxWidth > 0, size.width > maxWidth {
            size = NSSize(width: maxWidth, height: size.height * (maxWidth / size.width))
        }
        return FragmentOverlay(image: image,
                               bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    }
}

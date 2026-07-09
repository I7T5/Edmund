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
// relative paths resolve against the document's directory. A remote `https`
// image loads only when `allowRemoteImages` is on (mirrors Read mode's
// `allowRemoteImages`/`blockExternalImages`), and asynchronously — loading it
// synchronously on the styling path would block the main thread. `http` never
// loads: App Transport Security refuses the insecure connection outright,
// regardless of the setting (same reasoning as Read mode's DocumentHTML).

// Loaded images are cached by resolved absolute path (local) or URL string
// (remote), so a recompose doesn't re-read/re-fetch them. NSCache is
// internally thread-safe.
nonisolated(unsafe) private let imageCache = NSCache<NSString, NSImage>()

// Remote URLs currently being fetched, so a burst of re-styles (scrolling,
// cursor moves near the image) doesn't kick off duplicate downloads. Mutated
// only on the main actor: inserted synchronously from `loadRemoteImage`
// (called while styling, always on the main thread) and removed inside the
// fetch completion's `@MainActor` hop.
nonisolated(unsafe) private var inFlightRemoteImages = Set<String>()

extension EditorTextView {

    /// Loads the image referenced by an `![alt](destination)` link, or nil if it
    /// can't be resolved/loaded (yet) — the caller then shows the raw alt text.
    func loadImage(destination: String) -> NSImage? {
        let dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = URL(string: dest)?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            guard scheme == "https", allowRemoteImages else { return nil }
            return loadRemoteImage(dest)
        }
        guard let url = resolveImageURL(dest) else { return nil }
        let key = url.path as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    /// Returns the cached image for a remote `urlString` if already downloaded;
    /// otherwise starts an async fetch (once per URL, while one is already in
    /// flight) and returns nil for now. The completion caches the image and
    /// re-styles the document so it appears — without blocking the main thread
    /// on network I/O.
    private func loadRemoteImage(_ urlString: String) -> NSImage? {
        let key = urlString as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard !inFlightRemoteImages.contains(urlString), let url = URL(string: urlString) else { return nil }
        inFlightRemoteImages.insert(urlString)

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else {
                Task { @MainActor in inFlightRemoteImages.remove(urlString) }
                return
            }
            Task { @MainActor in
                imageCache.setObject(image, forKey: urlString as NSString)
                inFlightRemoteImages.remove(urlString)
                self?.recomposeAllDirty()
            }
        }.resume()
        return nil
    }

    /// Resolves a destination string to a local file URL. Returns nil for a
    /// remote URL (handled separately, before this is reached) or when a
    /// relative path can't be anchored.
    private func resolveImageURL(_ destination: String) -> URL? {
        let dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return nil }

        if let url = URL(string: dest), let scheme = url.scheme {
            return scheme == "file" ? url : nil
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

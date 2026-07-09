import AppKit

// MARK: - Image Rendering
//
// `![alt](path)` renders the referenced image inline when the cursor is outside
// the token, and shows the raw, editable markdown when the cursor is inside it
// (the `.image` branch of `styleBlock`). A loaded image is drawn by a
// `FragmentOverlay` anchored on the leading `!` — the same mechanism math and
// list markers use — with the rest of the markdown hidden and the line height
// reserved for the picture. An image that can't be shown (outside the token)
// gets the same overlay treatment, but with a small icon + reason in place of
// the picture, so the user knows *why* — not just that nothing rendered.
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

// Remote URLs that were fetched and turned out not to decode as an image, so
// repeated re-styles show "Not an image" instead of re-fetching forever.
nonisolated(unsafe) private var undecodableRemoteImages = Set<String>()

extension EditorTextView {

    /// Why an `![alt](destination)` couldn't be shown — the short label the
    /// placeholder overlay draws next to its icon.
    enum ImageLoadFailure {
        case httpUnsupported
        case blockedBySetting
        case notAnImage
        case notFound

        var label: String {
            switch self {
            case .httpUnsupported: return "HTTP connection not supported"
            case .blockedBySetting: return "External images blocked"
            case .notAnImage: return "Not an image"
            case .notFound: return "Image not found"
            }
        }
    }

    /// What `styleBlock` should show for an image token when the cursor is
    /// outside it.
    enum ImageDisplay {
        /// The image loaded; draw it.
        case image(NSImage)
        /// It can't be shown; draw an icon + `failure.label` in its place.
        case blocked(ImageLoadFailure)
        /// A remote fetch is in flight — transient, not an error; the caller
        /// falls back to plain alt text until a recompose picks up the result.
        case pending
    }

    /// Resolves and (for local files) loads the image referenced by
    /// `destination`, classifying why it can't be shown when it can't.
    func imageDisplay(destination: String) -> ImageDisplay {
        let dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return .blocked(.notFound) }

        if let scheme = URL(string: dest)?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            guard scheme == "https" else { return .blocked(.httpUnsupported) }
            guard allowRemoteImages else { return .blocked(.blockedBySetting) }
            return loadRemoteImage(dest)
        }
        guard let url = resolveImageURL(dest) else { return .blocked(.notFound) }
        let key = url.path as NSString
        if let cached = imageCache.object(forKey: key) { return .image(cached) }
        // `resolveImageURL` builds a URL from the path string alone (it doesn't
        // check existence), so a missing file and an undecodable one both fail
        // `NSImage(contentsOf:)` the same way — check existence first so the two
        // get distinct, accurate messages.
        guard FileManager.default.fileExists(atPath: url.path) else { return .blocked(.notFound) }
        guard let image = NSImage(contentsOf: url) else { return .blocked(.notAnImage) }
        imageCache.setObject(image, forKey: key)
        return .image(image)
    }

    /// Returns the cached/decoded outcome for a remote `urlString`; otherwise
    /// starts an async fetch (once per URL, while one is already in flight)
    /// and returns `.pending`. The completion caches the image (or remembers a
    /// decode failure) and re-styles the document so the result appears —
    /// without blocking the main thread on network I/O.
    private func loadRemoteImage(_ urlString: String) -> ImageDisplay {
        let key = urlString as NSString
        if let cached = imageCache.object(forKey: key) { return .image(cached) }
        if undecodableRemoteImages.contains(urlString) { return .blocked(.notAnImage) }
        guard !inFlightRemoteImages.contains(urlString), let url = URL(string: urlString) else { return .pending }
        inFlightRemoteImages.insert(urlString)

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            Task { @MainActor in
                inFlightRemoteImages.remove(urlString)
                if let image {
                    imageCache.setObject(image, forKey: urlString as NSString)
                } else {
                    undecodableRemoteImages.insert(urlString)
                }
                self?.recomposeAllDirty()
            }
        }.resume()
        return .pending
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

    /// A `FragmentOverlay` for `destination`'s image or placeholder, or nil
    /// while a remote fetch is pending (the caller then shows plain alt text).
    func imageOverlay(destination: String) -> FragmentOverlay? {
        switch imageDisplay(destination: destination) {
        case .image(let image):
            return scaledOverlay(image: image)
        case .blocked(let failure):
            return placeholderOverlay(failure: failure)
        case .pending:
            return nil
        }
    }

    /// Scales `image` down to fit the text width while keeping its aspect
    /// ratio. `bounds.minY == 0` sits the image bottom on the text baseline
    /// (the reserved line height makes room above it).
    private func scaledOverlay(image: NSImage) -> FragmentOverlay? {
        var size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let maxWidth = availableContentWidth
        if maxWidth > 0, size.width > maxWidth {
            size = NSSize(width: maxWidth, height: size.height * (maxWidth / size.width))
        }
        return FragmentOverlay(image: image,
                               bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    }

    /// Draws "icon  reason" into one image (same technique as the callout
    /// header: `LucideIcons.image` tinted to match the muted text), so a
    /// blocked/missing/undecodable image reads at a glance instead of just
    /// showing nothing.
    private func placeholderOverlay(failure: ImageLoadFailure) -> FragmentOverlay? {
        let pointSize = bodyFont.pointSize
        guard let icon = LucideIcons.image("image-off", color: .secondaryLabelColor, pointSize: pointSize)
        else { return nil }

        let labelAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor]
        let label = NSAttributedString(string: failure.label, attributes: labelAttrs)
        let labelSize = label.size()

        let gap = pointSize * 0.3
        let iconW = icon.size.width, iconH = icon.size.height
        let height = ceil(max(iconH, labelSize.height))
        let width = ceil(iconW + gap + labelSize.width)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: (height - iconH) / 2, width: iconW, height: iconH))
            label.draw(at: NSPoint(x: iconW + gap, y: (height - labelSize.height) / 2))
            return true
        }
        image.cacheMode = .never   // re-rasterize at the screen's backing scale, like the callout header

        return FragmentOverlay(image: image, bounds: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

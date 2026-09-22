import AppKit

// MARK: - LocalImageInlining
//
// Shared resolution + data-URI inlining for locally-referenced images. Used by
// `DocumentHTML` (Read mode / PDF export) and `SelfContainedMarkdown` (the
// self-contained markdown export), so both agree on what counts as a local
// image and how it is inlined.
enum LocalImageInlining {

    /// Resolves a local image `path` to a file URL: absolute / `~` / `file:`
    /// load directly; a relative path resolves against the document's
    /// directory. Remote URLs (`http`/`https`/`data:`) return nil — the caller
    /// handles those before reaching here. Existence is NOT checked for the
    /// absolute/`~` branches (only the relative branch), so callers that need
    /// to distinguish "missing" from "undecodable" must check existence first.
    static func resolve(_ path: String, baseURL: URL?) -> URL? {
        if let url = URL(string: path), let scheme = url.scheme {
            return scheme == "file" ? url : nil
        }
        // A markdown image destination may be percent-encoded (e.g. `%20`).
        let decoded = path.removingPercentEncoding ?? path
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded) }
        if decoded.hasPrefix("~") { return URL(fileURLWithPath: (decoded as NSString).expandingTildeInPath) }
        guard let baseURL else { return nil }
        let resolved = baseURL.appendingPathComponent(decoded)
        return FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
    }

    /// True when `destination` is a remote (`http(s)`) or already-inlined
    /// (`data:`) source — i.e. not something `resolve` could map to a file.
    static func isRemoteOrInlined(_ destination: String) -> Bool {
        let lower = destination.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("data:")
    }

    /// Reads an image file and returns a `data:` URI, with the MIME type guessed
    /// from the file extension (covers the common web image formats). Decodes
    /// the bytes first (discarding the result) so a file that merely has an
    /// image extension but isn't actually image data is caught here — as nil —
    /// rather than silently inlining garbage the browser then fails to render
    /// with no explanation.
    static func dataURI(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return nil }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "png":          mime = "image/png"
        case "jpg", "jpeg":  mime = "image/jpeg"
        case "gif":          mime = "image/gif"
        case "svg":          mime = "image/svg+xml"
        case "webp":         mime = "image/webp"
        case "bmp":          mime = "image/bmp"
        case "tiff", "tif":  mime = "image/tiff"
        default:             mime = "application/octet-stream"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }
}

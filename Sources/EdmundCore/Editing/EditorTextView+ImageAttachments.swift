import AppKit
import UniformTypeIdentifiers

// MARK: - Image Attachments (paste & drag)
//
// Obsidian-style image insertion without a vault: pasting or dropping an image
// copies it into a sibling `<docname>.assets/` folder next to the document and
// inserts a standard `![](relative-path)` — which the existing image rendering
// (EditorTextView+ImageRendering) already resolves against the document's
// directory. The working file stays plain, portable markdown; the assets folder
// travels with it (commit both and GitHub renders the images natively).
//
// Sources handled, in priority order:
//   1. Image *files* (Finder copy/drag): copied into the assets folder —
//      except Option-drop, which inserts a path reference without copying.
//   2. Raw image *data* (screenshots, copied bitmaps): written as PNG with a
//      timestamped filename (`pasted-yyyyMMdd-HHmmss.png`, lowercase and
//      space-free so the path is URL-safe on case-sensitive hosts like GitHub).
//   3. Remote image *URLs* (dragged/copied from a browser): inserted as-is.
//      Edmund is offline-by-default, so the image is never downloaded — Read
//      mode/export decide whether to load it (`allowRemoteImages`).
//
// Unsaved documents have no directory to anchor a relative path to, so the
// attach flow goes through `requestSaveForAttachment` (wired by Document to
// the standard save panel) and continues once the document is saved.
//
// All insertions funnel through `applyFormattingEdit` — a single undoable
// text step. Undo removes the markdown; the copied file stays on disk (it may
// already be referenced elsewhere, and re-pasting recreates it anyway).

extension EditorTextView {

    // MARK: Paste
    //
    // Why Edit ▸ Paste needs help: `importsGraphics` is off (an
    // NSTextAttachment in the storage would break the storage == rawSource
    // invariant), so stock NSTextView declares images unreadable and *disables
    // Paste entirely* when the clipboard holds only an image — `paste(_:)`
    // would never fire. The force-enable lives in the class's single
    // `validateMenuItem` override (EditorTextView+FormattingCommands), gated on
    // `Self.pasteboardHasImageContent`; the actual image handling is ours and
    // super never sees an image-bearing pasteboard.

    /// Cheap presence check for anything attachable (image files, bitmap data,
    /// web URLs) by type name only — no data reads — so it's safe to call from
    /// menu-validation paths.
    static func pasteboardHasImageContent(_ pasteboard: NSPasteboard) -> Bool {
        let types = Set(pasteboard.types ?? [])
        return !types.isDisjoint(with: [.png, .tiff, .fileURL, .URL])
    }

    /// Intercepts image content on the general pasteboard; everything else
    /// falls through to the normal text paste. The `paste(_:)` override itself
    /// lives in EditorTextView+TableCopy (the single override for this class),
    /// which calls here first.

    // MARK: Drag & drop

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.imageContentKind(of: sender.draggingPasteboard) != nil { return .copy }
        return super.draggingEntered(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.imageContentKind(of: sender.draggingPasteboard) != nil { return .copy }
        return super.draggingUpdated(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard Self.imageContentKind(of: pasteboard) != nil else {
            return super.performDragOperation(sender)
        }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        // Option-drop links to the file in place instead of copying it into
        // the assets folder. `NSEvent.modifierFlags` reads the live modifier
        // state (there is no key event in flight during a drag).
        let linkOnly = NSEvent.modifierFlags.contains(.option)
        return handleImagePasteboard(pasteboard, at: index, linkOnly: linkOnly)
    }

    // MARK: Pasteboard handling

    /// What kind of image content a pasteboard carries, if any. Drives both
    /// the drag-acceptance checks and the actual insert.
    enum ImageContentKind {
        case files([URL])
        case data(Data)   // PNG-encoded
        case remoteURL(URL)
    }

    /// Classifies the pasteboard's image content without mutating anything.
    /// Returns nil for non-image content (text, non-image files), which the
    /// caller then routes to the default paste/drop behavior.
    static func imageContentKind(of pasteboard: NSPasteboard) -> ImageContentKind? {
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let imageFiles = fileURLs.filter(isImageFile)
        if !imageFiles.isEmpty { return .files(imageFiles) }
        if let png = pngData(from: pasteboard) { return .data(png) }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let remote = urls.first(where: {
               ($0.scheme == "https" || $0.scheme == "http") && isImagePath($0.path)
           }) {
            return .remoteURL(remote)
        }
        return nil
    }

    /// Consumes the pasteboard's image content, if any: attaches files/data to
    /// the assets folder (or links with `linkOnly`) and inserts the markdown at
    /// `index` (nil → the current selection, paste semantics). Returns false
    /// when the pasteboard has no image content and the caller should fall
    /// through to default handling.
    @discardableResult
    func handleImagePasteboard(_ pasteboard: NSPasteboard, at index: Int?,
                               linkOnly: Bool) -> Bool {
        guard isEditable else { return false }   // Read mode: never mutates
        guard let kind = Self.imageContentKind(of: pasteboard) else { return false }
        switch kind {
        case .files(let urls):
            withSavedDocument { self.attachImageFiles(urls, copy: !linkOnly, at: index) }
        case .data(let png):
            withSavedDocument { self.attachImageData(png, at: index) }
        case .remoteURL(let url):
            // Nothing to write to disk — no save needed even for untitled docs.
            insertImageDestinations([url.absoluteString], at: index)
        }
        return true
    }

    // MARK: Return inside an image token

    /// A plain Return inside an `![alt](path)` token (or `<img …>`, `![[embed]]`)
    /// splits the destination in half and silently breaks the image — most
    /// reachably right after a paste, when the caret sits in the fresh token's
    /// alt-text slot and the user types a caption then hits Return. Redirect
    /// the break to just after the token instead: the image stays whole on its
    /// line and the caret lands on a fresh line below it. Returns false when
    /// the caret isn't strictly inside an image token (at its very first
    /// character, a plain newline already breaks *before* the image, keeping
    /// it whole — no redirect needed).
    @discardableResult
    func handleImageNewline(_ sel: NSRange) -> Bool {
        guard sel.length == 0,
              let blockIdx = blockIndexForRawOffset(sel.location),
              blockIdx < blocks.count else { return false }
        let base = blocks[blockIdx].range.location
        let inBlock = sel.location - base
        for span in SyntaxHighlighter.parse(blocks[blockIdx].content,
                                            features: markdownFeatures) {
            guard case .image = span.kind else { continue }
            let full = span.fullRange
            guard inBlock > full.location, inBlock < full.upperBound else { continue }
            insertText("\n", replacementRange: NSRange(location: base + full.upperBound,
                                                       length: 0))
            return true
        }
        return false
    }

    /// Runs `work` once the document has a file URL, triggering the app-layer
    /// save flow for an unsaved document (the assets folder is a sibling of the
    /// document file, so there is nowhere to put it until then). Without a
    /// document or save hook (unit tests) an attach is refused outright —
    /// inserting a path that can't resolve would be worse than doing nothing.
    private func withSavedDocument(then work: @escaping () -> Void) {
        if document?.fileURL != nil { work(); return }
        guard let requestSaveForAttachment else {
            NSSound.beep()
            return
        }
        requestSaveForAttachment { saved in if saved { work() } }
    }

    // MARK: Attach

    /// Inserts `![](…)` for each file. With `copy`, files are first copied into
    /// the document's assets folder (a file already inside it is left alone);
    /// without it, the file is referenced where it sits (Option-drop).
    func attachImageFiles(_ urls: [URL], copy: Bool, at index: Int?) {
        var destinations: [String] = []
        for url in urls {
            if copy {
                if let copied = copyIntoAssets(url) {
                    destinations.append(imageDestination(for: copied))
                } else {
                    // Copy failed (permissions, missing source): reference the
                    // original rather than dropping the user's content.
                    Log.error("Could not copy \(url.lastPathComponent) into assets; linking instead",
                              category: .io)
                    destinations.append(imageDestination(for: url))
                }
            } else {
                destinations.append(imageDestination(for: url))
            }
        }
        insertImageDestinations(destinations, at: index)
    }

    /// Writes PNG data into the assets folder under a timestamped name and
    /// inserts the markdown for it.
    func attachImageData(_ png: Data, at index: Int?) {
        guard let assets = assetsDirectoryURL(),
              let dest = uniqueURL(in: assets, base: Self.pastedImageBaseName(), ext: "png")
        else { NSSound.beep(); return }
        do {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            try png.write(to: dest, options: .atomic)
        } catch {
            Log.error("Could not write pasted image: \(error.localizedDescription)", category: .io)
            NSSound.beep()
            return
        }
        insertImageDestinations([imageDestination(for: dest)], at: index)
    }

    /// Inserts `![](dest)` (one per destination, blank-line separated) at
    /// `index`, or replacing the current selection when `index` is nil.
    /// A single image lands the caret in its alt-text slot — the one part of
    /// the syntax still missing — matching Image ▸ Attach File.
    func insertImageDestinations(_ destinations: [String], at index: Int?) {
        guard !destinations.isEmpty else { return }
        let text = destinations.map { "![](\($0))" }.joined(separator: "\n\n")
        let insertRange: NSRange
        if let index {
            insertRange = NSRange(location: min(index, (rawSource as NSString).length), length: 0)
        } else {
            insertRange = selectedRange()
        }
        let caret: NSRange
        if destinations.count == 1 {
            caret = NSRange(location: insertRange.location + 2, length: 0)
        } else {
            caret = NSRange(location: insertRange.location + (text as NSString).length, length: 0)
        }
        applyFormattingEdit(rawRange: insertRange, replacement: text, select: caret)
    }

    // MARK: Assets folder

    /// `<docname>.assets/` next to the document file (nil for an unsaved
    /// document). Per-document — not a shared `assets/` — so moving or
    /// deleting a document keeps its attachments together.
    func assetsDirectoryURL() -> URL? {
        guard let file = document?.fileURL else { return nil }
        let base = file.deletingPathExtension().lastPathComponent
        return file.deletingLastPathComponent()
            .appendingPathComponent(base + ".assets", isDirectory: true)
    }

    /// Copies `source` into the document's assets folder, returning the copy's
    /// URL. A file already inside the folder is returned as-is. Name collisions
    /// get a `-2`, `-3`, … suffix. Returns nil when the document is unsaved or
    /// the copy fails.
    func copyIntoAssets(_ source: URL) -> URL? {
        guard let assets = assetsDirectoryURL() else { return nil }
        let fm = FileManager.default
        if source.standardizedFileURL.deletingLastPathComponent()
            == assets.standardizedFileURL { return source }
        guard let dest = uniqueURL(in: assets,
                                   base: source.deletingPathExtension().lastPathComponent,
                                   ext: source.pathExtension) else { return nil }
        do {
            try fm.createDirectory(at: assets, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: dest)
            return dest
        } catch {
            Log.error("Could not copy \(source.path) into assets: \(error.localizedDescription)",
                      category: .io)
            return nil
        }
    }

    /// `base.ext` in `dir`, or `base-2.ext`, `base-3.ext`, … when the name is
    /// taken. Nil when `base` is empty (a nameless source).
    func uniqueURL(in dir: URL, base: String, ext: String) -> URL? {
        guard !base.isEmpty else { return nil }
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// The timestamped base name for pasted images: `pasted-yyyyMMdd-HHmmss`.
    /// Lowercase, digits and hyphens only — safe in a URL on case-sensitive
    /// hosts (GitHub) and sorting chronologically in Finder.
    static func pastedImageBaseName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "pasted-" + formatter.string(from: date)
    }

    // MARK: Pasteboard decoding

    /// PNG data from the pasteboard: an offered PNG is used as-is; TIFF (what
    /// screenshots and most copied bitmaps arrive as) is transcoded to PNG —
    /// lossless, universally readable, and much smaller on the wire.
    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png), NSImage(data: png) != nil {
            return png
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    /// `nonisolated`: a pure UTType query, and it is passed as an unapplied
    /// reference to `filter` — under older Swift 6 toolchains an actor-isolated
    /// reference there both errors and makes the rethrows call "can throw".
    nonisolated static func isImageFile(_ url: URL) -> Bool {
        isImagePath(url.path)
    }

    private nonisolated static func isImagePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return false }
        return UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
    }
}

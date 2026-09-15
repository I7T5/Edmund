import AppKit

// MARK: - Internal Link Following
//
// `[[wikilinks]]` and regular `[](dest)` links share one navigation core:
//   - `#heading`            → scroll to a heading in the current document,
//   - `path` / `path#head`  → resolve a file under the opened file's directory
//                             (a direct child, else a recursive search), open
//                             it, and scroll to the heading if one was named,
//   - external URL (scheme) → open in the default app (regular links only).
//
// Resolution needs only the opened file (its directory), not a vault folder.

/// Implemented by the owning document so a freshly opened document can be
/// scrolled to a heading after a cross-file link is followed.
@MainActor
public protocol HeadingNavigable: AnyObject {
    func navigateToHeading(_ heading: String)
}

extension EditorTextView {

    // MARK: Hit testing

    /// The wikilink target under a mouse event, or nil if the click doesn't land
    /// on wikilink display text.
    func wikiTarget(at event: NSEvent) -> String? {
        guard let storage = textStorage, let i = clickCharIndex(at: event) else { return nil }
        return storage.attribute(.editorWikiTarget, at: i, effectiveRange: nil) as? String
    }

    // MARK: Following

    /// Follows a `[[wikilink]]` target (`path#heading`, no scheme, `.md` implied).
    public func followWikiLink(_ target: String) {
        let (path, heading) = Self.splitHeading(target)
        if path.isEmpty {
            if let heading { scrollToHeading(heading) } else { NSSound.beep() }
            return
        }
        openLinkedFile(path: path, heading: heading)
    }

    /// Follows a regular markdown link destination: an external URL opens in the
    /// default app; `#heading` scrolls in-document; a local `path#heading`
    /// resolves a file and opens it (scrolling to the heading if named).
    public func followLinkDestination(_ destination: String) {
        let dest = destination.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: dest), let scheme = url.scheme, scheme != "file" {
            NSWorkspace.shared.open(url)
            return
        }
        // A markdown link destination is URL-encoded (e.g. `%20` for a space),
        // so decode both the path and the heading anchor.
        let (rawPath, rawHeading) = Self.splitHeading(dest)
        let path = rawPath.removingPercentEncoding ?? rawPath
        let heading = rawHeading.map { $0.removingPercentEncoding ?? $0 }
        if path.isEmpty {
            if let heading { scrollToHeading(heading) } else { NSSound.beep() }
            return
        }
        openLinkedFile(path: path, heading: heading)
    }

    /// Resolves `path` to a file and opens it, scrolling the opened document to
    /// `heading` when one is named (cross-file, via `HeadingNavigable`).
    private func openLinkedFile(path: String, heading: String?) {
        let resolved = resolveLinkedFile(path)
        guard let fileURL = resolved, FolderAccess.covers(fileURL) else {
            // Sandboxed and the folder isn't granted: the recursive search
            // can't run and `openDocument` would fail with a permission alert.
            // Offer the grant, then retry (once granted, `covers` is true).
            if ungrantedDocumentFolder != nil {
                requestFolderAccess { [weak self] in self?.openLinkedFile(path: path, heading: heading) }
            } else {
                NSSound.beep()
            }
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: fileURL, display: true) { _, _, _ in
            guard let heading else { return }
            // Re-find the document by URL on the main actor (the NSDocument
            // isn't Sendable, so we don't capture it across the boundary). By
            // now its content has loaded (showWindows → loadContent).
            Task { @MainActor in
                let doc = NSDocumentController.shared.document(for: fileURL)
                (doc as? HeadingNavigable)?.navigateToHeading(heading)
            }
        }
    }

    // MARK: Heading navigation

    /// Scrolls to the first heading block whose text matches `heading`
    /// (case-insensitive), or — when `heading` is a `^blockid` fragment — to the
    /// block defining that id. Beeps if there is no match. This is the single
    /// chokepoint every internal-link caller funnels through (`[[#heading]]`,
    /// `[[note#heading]]`, `[[#^id]]`, `[[note#^id]]`, and cross-file opens via
    /// `navigateToHeading`), so block-id dispatch and the Edit/Read surface
    /// switch both live here.
    public func scrollToHeading(_ heading: String) {
        if heading.hasPrefix("^") {
            scrollToBlockID(String(heading.dropFirst()))
            return
        }
        let want = heading.lowercased()
        for block in blocks {
            guard case .heading = block.kind,
                  Self.headingText(block.content).lowercased() == want else { continue }
            scrollToBlock(block.range)
            return
        }
        NSSound.beep()
    }

    /// Scrolls to the block that defines the Obsidian `^id` block reference
    /// (a trailing `^id` at the end of a block). Beeps if none does.
    public func scrollToBlockID(_ id: String) {
        for block in blocks {
            var refs: [SyntaxHighlighter.Span] = []
            SyntaxHighlighter.parseBlockRef(block.content, into: &refs)
            let matches = refs.contains {
                if case .blockRef(let bid) = $0.kind { return bid == id }
                return false
            }
            if matches { scrollToBlock(block.range); return }
        }
        NSSound.beep()
    }

    /// Brings `range`'s block into view. In Edit/Source the editor selects the
    /// block (a visible highlight) and scrolls to it; in Read mode the editor is
    /// hidden, so it scrolls the web view instead — mapping the block's source
    /// line to the nearest top-level anchor the read view actually carries.
    private func scrollToBlock(_ range: NSRange) {
        if viewMode == .reading {
            let line = line(forOffset: range.location)
            // Anchors exist only on top-level block starts; snap `line` to the
            // enclosing block's start so `edmund-l<line>` resolves (reuses the
            // same span map the Read→Edit round trip uses in reverse).
            let spans = ReadModeAnchors.topLevelBlockSpans(for: rawSource)
            let anchorLine = spans.first(where: { $0.startLine <= line && line <= $0.endLine })?.startLine
                ?? spans.last(where: { $0.startLine <= line })?.startLine
                ?? line
            onReadScrollToLine?(anchorLine)
        } else {
            setSelectedRange(range)
            scrollRangeToVisible(range)
        }
    }

    /// The text of a heading line, stripped of its leading `#`s and whitespace.
    static func headingText(_ line: String) -> String {
        var s = Substring(line)
        while s.first == "#" { s = s.dropFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Splits `path#heading` (or `#heading`, or `path`) into a path and the
    /// deepest heading component (so `Note#H1#H2` targets `H2`). A nil heading
    /// means none was named.
    static func splitHeading(_ s: String) -> (path: String, heading: String?) {
        let ns = s as NSString
        let hash = ns.range(of: "#")
        guard hash.location != NSNotFound else {
            return (s.trimmingCharacters(in: .whitespaces), nil)
        }
        let path = ns.substring(to: hash.location).trimmingCharacters(in: .whitespaces)
        let rest = ns.substring(from: hash.upperBound)
        let heading = rest.split(separator: "#").last
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return (path, heading)
    }

    // MARK: File resolution

    /// Resolves a link `path` to a file URL. Absolute / `~` / `file:` paths load
    /// directly; otherwise it resolves under the opened file's directory — a
    /// direct child first, else a recursive search by filename — appending `.md`
    /// when the path has no extension (Obsidian-style wikilinks omit it).
    func resolveLinkedFile(_ path: String) -> URL? {
        if let url = URL(string: path), url.scheme == "file" { return url }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

        guard let docDir = document?.fileURL?.deletingLastPathComponent() else { return nil }
        let fm = FileManager.default
        let rel = (path as NSString).pathExtension.isEmpty ? path + ".md" : path

        let direct = docDir.appendingPathComponent(rel)
        if fm.fileExists(atPath: direct.path) { return direct }

        // Recursive search by the link's filename (Obsidian resolves by name).
        let wantName = (rel as NSString).lastPathComponent.lowercased()
        if let walker = fm.enumerator(at: docDir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.lastPathComponent.lowercased() == wantName {
                return url
            }
        }
        return nil
    }
}

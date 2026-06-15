import AppKit

// MARK: - Wikilink Following
//
// `[[target]]` links resolve relative to the *opened file's directory* — the
// app needs only the file, not a whole vault folder. A bare `#heading` scrolls
// to a heading in the current document; a `path` (optionally `path#heading`)
// resolves to a sibling `.md` file, falling back to a recursive search under
// the document's directory. Cross-file heading scrolling is not implemented yet
// (the file just opens).

extension EditorTextView {

    /// The wikilink target under a mouse event, or nil if the click doesn't land
    /// on wikilink display text.
    func wikiTarget(at event: NSEvent) -> String? {
        guard let storage = textStorage, let i = clickCharIndex(at: event) else { return nil }
        return storage.attribute(.editorWikiTarget, at: i, effectiveRange: nil) as? String
    }

    /// Resolves and navigates a wikilink `target` (`path#heading`):
    ///   - empty path (`#heading`) → scroll to that heading in this document,
    ///   - a path → open the resolved `.md` file (heading, if any, ignored).
    func followWikiLink(_ target: String) {
        let ns = target as NSString
        let hash = ns.range(of: "#")
        let path: String
        let heading: String?
        if hash.location == NSNotFound {
            path = target.trimmingCharacters(in: .whitespaces)
            heading = nil
        } else {
            path = ns.substring(to: hash.location).trimmingCharacters(in: .whitespaces)
            // For subheadings ("H1#H2") target the deepest component.
            let rest = ns.substring(from: hash.upperBound)
            heading = rest.split(separator: "#").last.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? rest.trimmingCharacters(in: .whitespaces)
        }

        if path.isEmpty {
            if let heading, !heading.isEmpty { scrollToHeading(heading) } else { NSSound.beep() }
            return
        }
        guard let fileURL = resolveWikiFile(path) else { NSSound.beep(); return }
        NSDocumentController.shared.openDocument(withContentsOf: fileURL, display: true) { _, _, _ in }
    }

    /// Scrolls to the first heading block whose text matches `heading`
    /// (case-insensitive). Beeps if there is no such heading.
    func scrollToHeading(_ heading: String) {
        let want = heading.lowercased()
        for block in blocks {
            guard case .heading = block.kind,
                  Self.headingText(block.content).lowercased() == want else { continue }
            let loc = block.range.location
            setSelectedRange(NSRange(location: loc, length: 0))
            scrollRangeToVisible(NSRange(location: loc, length: 0))
            return
        }
        NSSound.beep()
    }

    /// The text of a heading line, stripped of its leading `#`s and whitespace.
    static func headingText(_ line: String) -> String {
        var s = Substring(line)
        while s.first == "#" { s = s.dropFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Resolves a wikilink `path` (without `.md`) to a file URL under the
    /// document's directory: a direct sibling first, else a recursive search by
    /// filename. Returns nil if the document has no directory or no match.
    func resolveWikiFile(_ path: String) -> URL? {
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

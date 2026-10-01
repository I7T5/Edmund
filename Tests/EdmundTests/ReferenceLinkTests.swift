import Testing
import Foundation
import AppKit
@testable import EdmundCore

// MARK: - Reference link resolution (edit-mode parse)

@Suite("SyntaxHighlighter — Reference links")
struct ReferenceLinkTests {

    private func linkSpans(_ text: String, defs: String = "")
        -> [(range: NSRange, dest: String)] {
        SyntaxHighlighter.parse(text, linkDefinitions: defs).compactMap { s in
            guard case .link(let d) = s.kind else { return nil }
            return (s.fullRange, d)
        }
    }

    @Test("Full reference `[text][label]` resolves against an appended definition")
    func fullReference() {
        let links = linkSpans("see [text][bar] here", defs: "[bar]: https://e.com")
        #expect(links.count == 1)
        #expect(links[0].dest == "https://e.com")
        #expect(links[0].range == NSRange(location: 4, length: 11))   // [text][bar]
    }

    @Test("Collapsed reference `[label][]` resolves")
    func collapsedReference() {
        let links = linkSpans("a [foo][] b", defs: "[foo]: https://f.com")
        #expect(links.count == 1)
        #expect(links[0].dest == "https://f.com")
    }

    @Test("Shortcut reference `[label]` resolves")
    func shortcutReference() {
        let links = linkSpans("a [foo] b", defs: "[foo]: https://f.com")
        #expect(links.count == 1)
        #expect(links[0].dest == "https://f.com")
    }

    @Test("Label matching is case-insensitive (CommonMark)")
    func caseInsensitiveLabel() {
        let links = linkSpans("[Foo]", defs: "[foo]: https://f.com")
        #expect(links.count == 1)
        #expect(links[0].dest == "https://f.com")
    }

    @Test("Unknown label produces no link span (stays plain text)")
    func unknownLabel() {
        #expect(linkSpans("see [text][bar]", defs: "[other]: https://e.com").isEmpty)
    }

    @Test("Without definitions, a bare `[foo]` is not a link (regression)")
    func noDefinitionsNoLink() {
        #expect(linkSpans("a [foo] b").isEmpty)
    }

    @Test("Inline link `[t](url)` is unaffected by the append")
    func inlineLinkUnaffected() {
        let links = linkSpans("[t](https://x.com)", defs: "[bar]: https://e.com")
        #expect(links.count == 1)
        #expect(links[0].dest == "https://x.com")
    }

    @Test("Appended definition never leaks a span past the block")
    func noSpanLeaksIntoAppendedRegion() {
        let text = "[foo]"
        let spans = SyntaxHighlighter.parse(text, linkDefinitions: "[foo]: https://f.com")
        #expect(spans.allSatisfy { $0.fullRange.upperBound <= (text as NSString).length })
    }

    // An indented code block's node range runs past the block over the blank
    // separator line the append adds; the span must be clamped, not dropped,
    // or the block loses its monospace font (test.md "\tIndented").
    @Test("Indented code keeps its span when definitions are appended")
    func indentedCodeSurvivesAppend() {
        let text = "\tIndented"
        let spans = SyntaxHighlighter.parse(text, linkDefinitions: "[foo]: https://f.com")
        #expect(spans.contains { if case .codeBlock = $0.kind {
            return $0.fullRange == NSRange(location: 0, length: 9)
        }; return false })
    }
}

// MARK: - LinkDefinitionState

@Suite("LinkDefinitionState")
struct LinkDefinitionStateTests {

    @Test("build collects definition lines; defsText is sorted and deterministic")
    func buildCollectsAndSorts() {
        let s = LinkDefinitionState.build(from: "text\n[b]: u2\nmore\n[a]: u1")
        #expect(s.defsText == "[a]: u1\n[b]: u2")
    }

    @Test("No definitions yields empty defsText (parse skips the append)")
    func emptyWhenNoDefinitions() {
        #expect(LinkDefinitionState.build(from: "just prose\n[not a def]").defsText == "")
    }

    @Test("definitions(for:) keeps only the labels a block references")
    func definitionsForBlock() {
        var s = LinkDefinitionState.build(
            from: "[Foo Bar]: /a\n[x]: /x\n[^n1]: note\n[unused]: /u\n> [quoted]: /q")
        #expect(s.definitions(for: "no brackets here") == "")
        #expect(s.definitions(for: "see [foo   BAR]") == "[Foo Bar]: /a")
        #expect(s.definitions(for: "[text][x] and [x][] and [Foo\nbar]")
                == "[Foo Bar]: /a\n[x]: /x")
        #expect(s.definitions(for: "a footnote[^n1]") == "[^n1]: note")
        #expect(s.definitions(for: "[quoted]") == "[quoted]: /q")
        #expect(s.definitions(for: "[nothing defined]") == "")
        s.remove("[x]: /x")
        #expect(s.definitions(for: "[x]") == "")
    }

    @Test("add then remove of the same block content is exact")
    func addRemoveExact() {
        var s = LinkDefinitionState()
        s.add("[a]: u1")
        s.add("[b]: u2")
        s.remove("[a]: u1")
        #expect(s.defsText == "[b]: u2")
        s.remove("[b]: u2")
        #expect(s.defsText == "")
    }

    @Test("isDefinitionLine recognizes definitions and rejects non-definitions")
    func definitionLineDetection() {
        #expect(LinkDefinitionState.isDefinitionLine("[a]: https://e.com"))
        #expect(LinkDefinitionState.isDefinitionLine("   [a]: /path"))          // ≤3 spaces
        #expect(LinkDefinitionState.isDefinitionLine("[a]: u \"title\""))
        #expect(!LinkDefinitionState.isDefinitionLine("    [a]: u"))            // 4 spaces = code
        #expect(!LinkDefinitionState.isDefinitionLine("[a]:"))                  // empty dest
        #expect(!LinkDefinitionState.isDefinitionLine("[a] not a def"))
        #expect(!LinkDefinitionState.isDefinitionLine("plain text"))
    }

    @Test("Equatable ignores insertion order")
    func equatableOrderIndependent() {
        var a = LinkDefinitionState(); a.add("[x]: 1"); a.add("[y]: 2")
        var b = LinkDefinitionState(); b.add("[y]: 2"); b.add("[x]: 1")
        #expect(a == b)
    }

    @Test("Definition inside a block quote is collected (GFM ex. 187)")
    func definitionInsideBlockQuote() {
        #expect(LinkDefinitionState.canonicalDefinition(from: "> [foo]: /url") == "[foo]: /url")
        #expect(LinkDefinitionState.canonicalDefinition(from: ">> [foo]: /url") == "[foo]: /url")
        #expect(LinkDefinitionState.build(from: "> [foo]: /url").defsText == "[foo]: /url")
    }

    @Test("Definition on a list-marker line is collected")
    func definitionInsideListItem() {
        #expect(LinkDefinitionState.canonicalDefinition(from: "- [foo]: /url") == "[foo]: /url")
        #expect(LinkDefinitionState.canonicalDefinition(from: "1. [foo]: /url") == "[foo]: /url")
    }

    @Test("A task-list checkbox is not mistaken for a definition")
    func taskListNotDefinition() {
        #expect(LinkDefinitionState.canonicalDefinition(from: "- [ ] todo") == nil)
        #expect(LinkDefinitionState.canonicalDefinition(from: "- [x] done") == nil)
    }

    @Test("Container and plain forms of the same def dedupe to one line")
    func containerAndPlainDedupe() {
        var s = LinkDefinitionState()
        s.add("> [foo]: /url")
        s.add("[foo]: /url")
        #expect(s.defsText == "[foo]: /url")
    }
}

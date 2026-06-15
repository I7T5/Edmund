import Testing
import AppKit
@testable import MarkdownEditorCore

@Suite("Comments")
@MainActor
struct CommentRenderingTests {

    @Test("%%comment%% is parsed as a comment span")
    func parsesComment() {
        let spans = SyntaxHighlighter.parse("a %%hidden note%% b")
        let comment = spans.first { if case .comment = $0.kind { return true }; return false }
        #expect(comment != nil)
        #expect(comment?.fullRange == NSRange(location: 2, length: 15)) // "%%hidden note%%"
    }

    @Test("Comment content is opaque: inner markdown is not parsed")
    func opaque() {
        let spans = SyntaxHighlighter.parse("%%**bold** [x](y)%%")
        #expect(!spans.contains { if case .bold = $0.kind { return true }; return false })
        #expect(!spans.contains { if case .link = $0.kind { return true }; return false })
    }

    @Test("Edit view dims the comment but keeps it visible")
    func editDims() {
        let editor = makeEditor()
        let st = editor.styleBlock("see %%a note%% here", hideComments: false)
        let loc = (st.string as NSString).range(of: "a note").location
        #expect(!isHidden(at: loc, in: st))      // content visible
        #expect(isDimmed(at: loc, in: st))       // but dimmed
        let pct = (st.string as NSString).range(of: "%%").location
        #expect(!isHidden(at: pct, in: st))      // delimiters visible (dimmed)
    }

    @Test("Reading view hides the comment entirely")
    func readingHides() {
        let editor = makeEditor()
        let st = editor.styleBlock("see %%a note%% here", hideComments: true)
        let loc = (st.string as NSString).range(of: "a note").location
        let pct = (st.string as NSString).range(of: "%%").location
        #expect(isHidden(at: loc, in: st))       // content hidden
        #expect(isHidden(at: pct, in: st))       // delimiters hidden
        // Surrounding text is untouched.
        let here = (st.string as NSString).range(of: "here").location
        #expect(!isHidden(at: here, in: st))
    }

    @Test("Reading view via viewMode hides comments in the storage")
    func readingViewMode() {
        let editor = makeEditor()
        editor.loadContent("before %%secret%% after")
        editor.viewMode = .reading
        let loc = (editor.rawSource as NSString).range(of: "secret").location
        #expect(isHidden(at: loc, in: editor.textStorage!))
    }
}

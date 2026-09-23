import Testing
import AppKit
@testable import EdmundCore

/// `EditorTextStorage.string` used to bridge (copy) the whole document on every
/// call, and NSAttributedString's default `length` / `attributedSubstring(from:)`
/// go through it — so TextKit 2 copied the document for every paragraph it laid
/// out. These pin the no-copy paths and that the cached snapshot stays correct.
@Suite("EditorTextStorage string access")
struct EditorTextStorageStringTests {

    /// Counts reads of `string` so a test can assert a path never takes it.
    final class CountingStorage: EditorTextStorage {
        var stringReads = 0
        override var string: String {
            stringReads += 1
            return super.string
        }
    }

    @Test("length and attributedSubstring never read the whole string")
    func primitivesAvoidString() {
        let ts = CountingStorage()
        ts.replaceCharacters(in: NSRange(location: 0, length: 0), with: "hello\nworld\n")
        ts.stringReads = 0
        #expect(ts.length == 12)
        #expect(ts.attributedSubstring(from: NSRange(location: 6, length: 5)).string == "world")
        #expect(ts.stringReads == 0)
    }

    @Test("repeated string reads share one snapshot between edits")
    func snapshotIsReused() {
        let ts = EditorTextStorage()
        ts.replaceCharacters(in: NSRange(location: 0, length: 0), with: "abc")
        let a = ts.string as NSString
        let b = ts.string as NSString
        #expect(a === b)
    }

    @Test("string reflects every kind of edit")
    func snapshotInvalidates() {
        let ts = EditorTextStorage()
        ts.replaceCharacters(in: NSRange(location: 0, length: 0), with: "abc")
        #expect(ts.string == "abc")
        ts.replaceCharacters(in: NSRange(location: 1, length: 1),
                             with: NSAttributedString(string: "XY"))
        #expect(ts.string == "aXYc")
        ts.setAttributes([.foregroundColor: NSColor.red], range: NSRange(location: 0, length: 2))
        #expect(ts.string == "aXYc")
        ts.mutableString.append("!")
        #expect(ts.string == "aXYc!")
        #expect(ts.length == 5)
    }
}

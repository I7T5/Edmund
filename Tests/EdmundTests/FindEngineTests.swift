import Testing
import Foundation
@testable import EdmundCore

@Suite("FindEngine")
struct FindEngineTests {

    @Test("Empty needle matches nothing")
    func emptyNeedle() {
        #expect(FindEngine.matches(of: "", in: "anything").isEmpty)
    }

    @Test("Case-insensitive substring by default")
    func caseInsensitiveDefault() {
        let m = FindEngine.matches(of: "hi", in: "Hi hi HI")
        #expect(m == [NSRange(location: 0, length: 2),
                      NSRange(location: 3, length: 2),
                      NSRange(location: 6, length: 2)])
    }

    @Test("Case-sensitive toggle distinguishes case")
    func caseSensitive() {
        let m = FindEngine.matches(of: "Hi", in: "Hi hi HI", caseSensitive: true)
        #expect(m == [NSRange(location: 0, length: 2)])
    }

    @Test("Adjacent occurrences are all found")
    func adjacent() {
        let m = FindEngine.matches(of: "aa", in: "aaaa")
        // Non-overlapping: positions 0 and 2.
        #expect(m == [NSRange(location: 0, length: 2),
                      NSRange(location: 2, length: 2)])
    }

    @Test("Overlapping candidates do not double-count")
    func overlapping() {
        // "aba" in "ababa": only one non-overlapping hit at 0.
        let m = FindEngine.matches(of: "aba", in: "ababa")
        #expect(m == [NSRange(location: 0, length: 3)])
    }

    @Test("Whole-word rejects matches inside a larger word")
    func wholeWordBoundaries() {
        let hay = "cat category cat."
        let all = FindEngine.matches(of: "cat", in: hay)
        #expect(all.count == 3) // cat, cat(egory), cat
        let words = FindEngine.matches(of: "cat", in: hay, wholeWord: true)
        // The "cat" inside "category" is rejected; the two standalone ones stay.
        #expect(words == [NSRange(location: 0, length: 3),
                          NSRange(location: 13, length: 3)])
    }

    @Test("Whole-word matches at document edges")
    func wholeWordEdges() {
        let m = FindEngine.matches(of: "go", in: "go", wholeWord: true)
        #expect(m == [NSRange(location: 0, length: 2)])
    }

    @Test("No match returns empty")
    func noMatch() {
        #expect(FindEngine.matches(of: "zzz", in: "hello world").isEmpty)
    }
}

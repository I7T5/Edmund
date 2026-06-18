import Testing
import Foundation
@testable import EdmundCore

// MARK: - LineEnding

@Suite("LineEnding — Detection")
struct LineEndingDetectionTests {

    @Test("LF text detects as .lf")
    func detectsLF() {
        #expect(LineEnding.detect(in: "a\nb\nc") == .lf)
    }

    @Test("CRLF text detects as .crlf")
    func detectsCRLF() {
        #expect(LineEnding.detect(in: "a\r\nb\r\nc") == .crlf)
    }

    @Test("Lone CR text detects as .cr")
    func detectsCR() {
        #expect(LineEnding.detect(in: "a\rb\rc") == .cr)
    }

    @Test("Mixed content prefers CRLF when present")
    func mixedPrefersCRLF() {
        #expect(LineEnding.detect(in: "a\r\nb\nc") == .crlf)
    }

    @Test("Text with no breaks defaults to .lf")
    func noBreaksDefaultsLF() {
        #expect(LineEnding.detect(in: "single line") == .lf)
        #expect(LineEnding.detect(in: "") == .lf)
    }
}

@Suite("LineEnding — Normalization")
struct LineEndingNormalizationTests {

    @Test("CRLF normalizes to LF")
    func normalizeCRLF() {
        #expect(LineEnding.normalize("a\r\nb\r\nc") == "a\nb\nc")
    }

    @Test("Lone CR normalizes to LF")
    func normalizeCR() {
        #expect(LineEnding.normalize("a\rb\rc") == "a\nb\nc")
    }

    @Test("Mixed endings all normalize to LF")
    func normalizeMixed() {
        #expect(LineEnding.normalize("a\r\nb\rc\nd") == "a\nb\nc\nd")
    }

    @Test("Pure LF is unchanged")
    func normalizeLFUnchanged() {
        #expect(LineEnding.normalize("a\nb\nc") == "a\nb\nc")
    }

    @Test("string and displayName round-trip the cases")
    func stringAndDisplay() {
        #expect(LineEnding.lf.string == "\n")
        #expect(LineEnding.crlf.string == "\r\n")
        #expect(LineEnding.cr.string == "\r")
        #expect(LineEnding.lf.displayName == "LF")
        #expect(LineEnding.crlf.displayName == "CRLF")
        #expect(LineEnding.cr.displayName == "CR")
    }
}

import Testing
import Foundation
@testable import edmd

/// The help book is static HTML that build-app.sh copies into the bundle, so
/// nothing else notices a renamed page, a dropped anchor, or a bundle id that
/// no longer matches the app's Info.plist — Help Viewer just shows a blank or
/// "can't be found" page.
@Suite("Help book")
struct HelpBookTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let book = root.appendingPathComponent("Resources/Edmund.help/Contents")
    static let pages = book.appendingPathComponent("Resources/en.lproj")

    static func pageFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: pages, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "html" }
    }

    static func matches(_ pattern: String, in html: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).map {
            String(html[Range($0.range(at: 1), in: html)!])
        }
    }

    static func plist(_ url: URL) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
    }

    @Test func everyHelpButtonAnchorIsInTheBook() throws {
        var anchors = Set<String>()
        for page in try Self.pageFiles() {
            anchors.formUnion(try Self.matches(#"<a name="([^"]+)""#, in: String(contentsOf: page, encoding: .utf8)))
        }
        for anchor in HelpAnchor.all {
            #expect(anchors.contains(anchor), "no <a name=\"\(anchor)\"> in Edmund.help")
        }
    }

    @Test func everyLinkBetweenPagesResolves() throws {
        for page in try Self.pageFiles() {
            let html = try String(contentsOf: page, encoding: .utf8)
            for href in try Self.matches(##"href="([^"#:]+)"##, in: html) {
                let target = page.deletingLastPathComponent().appendingPathComponent(href)
                #expect(FileManager.default.fileExists(atPath: target.path),
                        "\(page.lastPathComponent) links to missing \(href)")
            }
        }
    }

    /// The sidebar is built from the list in toc.js, so a page missing from it
    /// can only be reached by search.
    @Test func contentsSidebarListsEveryPage() throws {
        let toc = try String(contentsOf: Self.book.appendingPathComponent("Resources/shared/toc.js"), encoding: .utf8)
        let listed = Set(try Self.matches(#""([a-z-]+\.html)""#, in: toc))
        let pages = Set(try Self.pageFiles().map(\.lastPathComponent))
        #expect(listed == pages)
    }

    @Test func appInfoPlistNamesTheBook() throws {
        let app = try Self.plist(Self.root.appendingPathComponent("Info.plist"))
        let book = try Self.plist(Self.book.appendingPathComponent("Info.plist"))
        #expect(app["CFBundleHelpBookFolder"] as? String == "Edmund.help")
        #expect(app["CFBundleHelpBookName"] as? String == book["CFBundleIdentifier"] as? String)
    }
}

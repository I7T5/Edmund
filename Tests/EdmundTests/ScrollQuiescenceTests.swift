import Testing
import AppKit
@testable import EdmundCore

@Suite("User-scroll quiescence")
@MainActor
struct ScrollQuiescenceTests {
    @Test("Programmatic scrolls do not pause styling or re-arm the user-scroll gate")
    func programmaticBoundsChanges() {
        let editor = makeEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.documentView = editor
        window.contentView = scroll
        editor.loadContent((0..<100).map { "line \($0)" }.joined(separator: "\n"))
        editor.sizeToFit()
        editor.installScrollPromotionObserver()

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        #expect(!editor.isScrollingActive)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification,
                                        object: scroll)
        #expect(editor.isScrollingActive)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification,
                                        object: scroll)
        // A viewport adjustment during the settle must not extend it.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        #expect(!editor.isScrollingActive)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        #expect(!editor.isScrollingActive)
    }
}

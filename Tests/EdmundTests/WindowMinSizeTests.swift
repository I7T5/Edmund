import Testing
import AppKit
import EdmundCore
@testable import edmd

/// The find bar must not decide how small the document window can get.
///
/// It is frame-managed (`autoresizingMask`), but its *contents* are laid out by
/// Auto Layout, so its required constraints reach the window as a
/// `contentMinSize`. A flexible-width autoresizing view only grows by the delta
/// from the width it was added at — so a bar parked at the default zero frame
/// only reaches the width its fields and buttons demand once the window is that
/// much wider than it opened. AppKit then took the minimum to be
/// `initial width + bar minimum` and inflated the opening frame to match, which
/// tied the window's initial size to its minimum and left `window.minSize`
/// doing nothing: an 800pt default opened at 1014pt and refused to shrink below
/// it, and dropping `minSize` to 320 changed neither number.
///
/// Only the live window server applies that minimum, so the window-level
/// symptom can't be asserted in-process (a headless `NSWindow` happily reports
/// a small `contentMinSize` and shrinks either way — both were tried, and both
/// passed against the bug). What is checkable here is the invariant the fix
/// rests on: the parked bar spans its container, so autoresizing keeps it
/// there instead of chasing the width the window opened at. Measured against
/// the running app: 800pt default → opens 800, shrinks to the 320 `minSize`.
@MainActor
@Suite("Document window minimum size")
struct WindowMinSizeTests {

    @Test("The parked find bar spans the container")
    func parkedBarSpansContainer() {
        let width: CGFloat = 800, height: CGFloat = 560

        // The document window's view stack, built the way
        // `makeWindowControllers` builds it: editor in a scroll view, status
        // bar over it, find bar added last.
        let editor = EditorTextView.makeTextKit2(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            containerSize: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let scrollView = NSScrollView(frame: container.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = editor
        let statusBar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        container.addSubview(scrollView)
        container.addSubview(statusBar)

        _ = FindController(editor: editor, scrollView: scrollView,
                           container: container, statusBar: statusBar)

        let bar = container.subviews.first { $0 is FindBarView }
        #expect(bar?.frame.width == width)
    }
}

import Testing
import AppKit
@testable import edmd

/// Regression for #278: activating the app with every window closed — a Dock
/// click, or opening the still-running app again — produced *two* blank
/// documents instead of one.
///
/// `applicationShouldHandleReopen` made the document itself and then returned
/// `true`, which is AppKit's "carry on with your normal handling". For a
/// document-based app with no windows that normal handling is
/// `_doOpenUntitled` → `applicationShouldOpenUntitledFile`, which answers yes
/// to the same "Create New Document" preference — so AppKit added a second
/// one. Captured live from two stacks under a single `_handleAEReopen:`.
///
/// AppKit's half of that race is out of reach in-process (there is no way to
/// make it run its default reopen handling here), so what is checkable is the
/// contract the fix rests on: once the delegate has handled the no-window
/// case, it must answer `false` so nothing else opens a document. Verified
/// against the running app: one `Untitled` per reopen, where 0.4.2 gave two.
@MainActor
@Suite("Reopen handling")
struct ReopenHandlingTests {

    /// Standing in for AppKit's own reopen handling, which only ever runs when
    /// the delegate returns `true`.
    ///
    /// The type method, not an `AppDelegate` instance: building one starts
    /// Sparkle (the stored `updaterController`), and a check that fails puts up
    /// a modal alert — which in a test run is a main thread nobody comes back to.
    private func shouldHandleReopen(hasVisibleWindows: Bool) -> Bool {
        AppDelegate.shouldHandleReopen(hasVisibleWindows: hasVisibleWindows)
    }

    @Test("With no windows left, the delegate claims the reopen")
    func claimsReopenWithNoWindows() {
        let saved = AppSettings.startupAction
        defer { AppSettings.startupAction = saved }

        // "Do Nothing" is the branch with no side effects: no document is made,
        // and AppKit must not make one either.
        AppSettings.startupAction = .doNothing
        #expect(shouldHandleReopen(hasVisibleWindows: false) == false)
    }

    /// The other way a second blank document appeared: after an *unclean* exit
    /// (crash, force quit) `applicationShouldTerminate` never runs, so the blank
    /// startup window stays archived and AppKit restores it at the next launch —
    /// through `NSDocumentController`'s restoration path, which neither
    /// `reopenDocument` nor `applicationShouldOpenUntitledFile` gates. An
    /// untitled document with nothing typed into it now isn't archived at all.
    @Test("A blank untitled window is archived only once it has been edited")
    func untitledWindowEarnsRestorability() {
        // A bare window rather than `makeWindowControllers()`, which builds the
        // whole document window (toolbar included) — the same reason every other
        // suite here assembles its own view stack.
        let document = Document()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        document.addWindowController(NSWindowController(window: window))

        // Nothing typed in yet: nothing a restored window could hand back.
        document.updateChangeCount(.changeCleared)
        #expect(window.isRestorable == false)

        // Crash recovery still applies the moment there is unsaved work.
        document.updateChangeCount(.changeDone)
        #expect(window.isRestorable == true)

        // …and stops applying if that work is undone away again.
        document.updateChangeCount(.changeUndone)
        #expect(window.isRestorable == false)
    }

    /// A miniaturized window still counts as visible, so this is the branch for
    /// windows that are merely hidden behind others — AppKit brings them
    /// forward, which is exactly the default handling we want to keep.
    @Test("With windows still open, AppKit's default handling is left alone")
    func defersToAppKitWithWindows() {
        let saved = AppSettings.startupAction
        defer { AppSettings.startupAction = saved }

        for action in AppSettings.StartupAction.allCases {
            AppSettings.startupAction = action
            #expect(shouldHandleReopen(hasVisibleWindows: true) == true)
        }
    }
}

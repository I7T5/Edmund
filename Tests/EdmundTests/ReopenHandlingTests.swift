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
    private func shouldHandleReopen(hasVisibleWindows: Bool) -> Bool {
        // `NSApp` is nil until something asks for the shared application; the
        // delegate ignores the sender, but the parameter still has to be real.
        AppDelegate().applicationShouldHandleReopen(NSApplication.shared,
                                                    hasVisibleWindows: hasVisibleWindows)
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

import Testing
import AppKit
@testable import edmd

@Suite struct WindowFrameRestoreTests {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func frameOnScreenIsKept() {
        let f = NSRect(x: 100, y: 100, width: 800, height: 600)
        #expect(AppSettings.reachableFrame(f, screens: [screen]) == f)
    }

    @Test func frameOnUnpluggedDisplayIsRejected() {
        let f = NSRect(x: 3000, y: 100, width: 800, height: 600)
        #expect(AppSettings.reachableFrame(f, screens: [screen]) == nil)
    }

    @Test func titleBarAboveMenuBarIsRejected() {
        let f = NSRect(x: 100, y: 1200, width: 800, height: 600)
        #expect(AppSettings.reachableFrame(f, screens: [screen]) == nil)
    }
}

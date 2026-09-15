import Testing
@testable import edmd

/// The Extensions sidebar is a `ScrollView` + `LazyVStack` (for pinned section
/// headers), not a `List`, so arrow-key movement is hand-written rather than
/// inherited. This is that movement's logic, isolated from the view.
@Suite("Extensions sidebar keyboard movement")
struct ExtensionsSidebarTests {

    private let ids = ["a", "b", "c"]

    @Test("Down and up step one row")
    func steps() {
        #expect(SettingsSidebar.neighbor(of: "a", in: ids, step: 1) == "b")
        #expect(SettingsSidebar.neighbor(of: "c", in: ids, step: -1) == "b")
    }

    @Test("Movement clamps at both ends instead of wrapping")
    func clampsAtEnds() {
        // Wrapping would jump the selection — and the detail pane with it — from
        // the last extension to the first on one keypress.
        #expect(SettingsSidebar.neighbor(of: "c", in: ids, step: 1) == "c")
        #expect(SettingsSidebar.neighbor(of: "a", in: ids, step: -1) == "a")
    }

    @Test("With nothing selected, movement enters from the near end")
    func entersFromNearEnd() {
        #expect(SettingsSidebar.neighbor(of: nil, in: ids, step: 1) == "a")
        #expect(SettingsSidebar.neighbor(of: nil, in: ids, step: -1) == "c")
    }

    @Test("An id that isn't on screen is treated as no selection")
    func unknownSelection() {
        // A collapsed section's rows are left out of the steppable list, so the
        // current selection can legitimately not be in it.
        #expect(SettingsSidebar.neighbor(of: "gone", in: ids, step: 1) == "a")
    }

    @Test("No rows means nowhere to move")
    func empty() {
        #expect(SettingsSidebar.neighbor(of: "a", in: [], step: 1) == nil)
    }
}

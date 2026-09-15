import AppKit

/// How far the search field insets its magnifier glyph from its leading edge —
/// AppKit's own inset is a tighter 3.5pt.
private let fieldContentInset: CGFloat = 6

// MARK: - Search field with an inline match count

/// Suppresses the stock magnifier ▾ glyph so the field can draw it centred
/// itself — see `CountingSearchField.draw(_:)`.
///
/// AppKit draws the glyph ~3.75pt below the field's centre (the image is 21×15,
/// the button rect the field's full 22pt height) and there is no built-in way to
/// move it: `searchButtonRect(forBounds:)` is only a sizing probe (it's called
/// with a 40000×40000 bounds), `drawInterior(withFrame:in:)` is bypassed by the
/// search field's private draw path, and the cell ignores a replacement image
/// (the Big Sur `NSSearchField` regression, FB8913004). `imageRect(forBounds:)`
/// *is* honoured, but the drawing is clipped to a fixed band, so shifting or
/// growing the rect only chops the top off the glyph. Zeroing it draws nothing,
/// which is the one thing we can use. The cell still handles the click, so the
/// search-options menu keeps working.
private final class BlankSearchButtonCell: NSButtonCell {
    override func imageRect(forBounds rect: NSRect) -> NSRect { .zero }
}

/// Reserves room on the right of the search text for the count label so the
/// typed text never runs under it.
private final class CountingSearchFieldCell: NSSearchFieldCell {
    var countWidth: CGFloat = 0
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var r = super.searchTextRect(forBounds: rect)
        r.size.width = max(0, r.width - countWidth)
        return r
    }
}

/// An `NSSearchField` that shows the match count inside the field, just left of
/// the cancel (✕) button — the Notes placement.
final class CountingSearchField: NSSearchField {
    private let countLabel = NSTextField(labelWithString: "")

    override class var cellClass: AnyClass? {
        get { CountingSearchFieldCell.self }
        set { }
    }

    /// Current match (0-based) and total; shown as "k of n". nil total or an
    /// empty query hides the count.
    var matchInfo: (current: Int?, total: Int)? { didSet { updateCount() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.isHidden = true
        addSubview(countLabel)
        recentreSearchButton()
    }

    /// Blank the search button cell, keeping its target/action so the
    /// search-options menu still opens; `draw(_:)` renders the glyph instead.
    private func recentreSearchButton() {
        guard let sfCell = cell as? NSSearchFieldCell,
              let old = sfCell.searchButtonCell else { return }
        let blank = BlankSearchButtonCell()
        blank.title = ""              // NSButtonCell defaults to drawing "Button"
        blank.imagePosition = .imageOnly
        blank.isBordered = old.isBordered
        blank.isTransparent = old.isTransparent
        blank.target = old.target
        blank.action = old.action
        sfCell.searchButtonCell = blank
    }

    // Ink sizes of the stock glyph, measured off a screenshot of the native
    // search field (device pixels ÷ 2). The magnifier and the ▾ are both centred
    // on the composite, so centring each on the button rect keeps their
    // relationship while lifting the whole glyph onto the field's centre. Their
    // leading edge is `fieldContentInset` rather than AppKit's own 3.5pt.
    private static let magnifierInkSize = NSSize(width: 12.5, height: 12.5)
    private static let chevronInkSize = NSSize(width: 6.1, height: 4.3)
    private static let chevronGap: CGFloat = 0.25   // measured, magnifier ink → ▾ ink
    /// Raises the glyph off the button rect's dead centre, which reads slightly
    /// low next to the text's x-height. Subtracted, because the field's
    /// coordinate space is flipped — smaller y is higher.
    private static let glyphLift: CGFloat = 0.5

    /// Draws the magnifier — and the ▾ search-menu affordance, when there is a
    /// menu — replicating the stock glyph, but centred on the button rect
    /// instead of sitting low in it.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let sfCell = cell as? NSSearchFieldCell else { return }
        let button = sfCell.searchButtonRect(forBounds: bounds)
        if let magnifier = Self.magnifier {
            draw(magnifier, inkAt: fieldContentInset, size: Self.magnifierInkSize, in: button)
        }
        if searchMenuTemplate != nil, let chevron = Self.menuChevron {
            draw(chevron, inkAt: fieldContentInset + Self.magnifierInkSize.width + Self.chevronGap,
                 size: Self.chevronInkSize, in: button)
        }
    }

    /// Scales and offsets `glyph` so its *ink* — not its padded image bounds —
    /// lands `x` points in from the *field's* leading edge, `size` big, and
    /// centred vertically on the button rect. SF Symbol images carry internal
    /// padding that varies with the symbol, so placing them by image bounds
    /// would miss the stock geometry; going through the ink makes the measured
    /// numbers exact.
    private func draw(_ glyph: (image: NSImage, ink: NSRect), inkAt x: CGFloat,
                      size: NSSize, in button: NSRect) {
        guard glyph.ink.width > 0, glyph.ink.height > 0 else { return }
        let sx = size.width / glyph.ink.width, sy = size.height / glyph.ink.height
        tint(glyph.image).draw(in: NSRect(
            x: bounds.minX + x - glyph.ink.minX * sx,
            y: button.midY - size.height / 2 - glyph.ink.minY * sy - Self.glyphLift,
            width: glyph.image.size.width * sx, height: glyph.image.size.height * sy))
    }

    // Point sizes chosen so the ink is already near its target size and the
    // rescale above stays ≈1 — scaling far from 1 would thicken or thin the
    // strokes away from the stock weight.
    private static let magnifier = glyph("magnifyingglass", pointSize: 13, weight: .light)
    private static let menuChevron = glyph("chevron.down", pointSize: 9, weight: .regular)

    private static func glyph(_ name: String, pointSize: CGFloat,
                              weight: NSFont.Weight) -> (image: NSImage, ink: NSRect)? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
        else { return nil }
        return (image, inkBounds(image))
    }

    /// Tight bounding box of an image's non-transparent pixels, in image points.
    private static func inkBounds(_ image: NSImage) -> NSRect {
        let scale = 2   // measure at 2× so half-point ink edges are visible
        let w = Int(image.size.width.rounded(.up)) * scale
        let h = Int(image.size.height.rounded(.up)) * scale
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return .zero }
        // Must be set before the context is made — it defines the context's
        // coordinate space, so a late assignment draws into the wrong scale.
        rep.size = image.size
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return .zero }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return .zero }
        let bytesPerRow = rep.bytesPerRow, perPixel = rep.samplesPerPixel
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[y * bytesPerRow + x * perPixel + 3] > 12 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return .zero }
        // Bitmap rows run top-down; NSImage coordinates run bottom-up.
        return NSRect(x: CGFloat(minX) / CGFloat(scale),
                      y: CGFloat(h - 1 - maxY) / CGFloat(scale),
                      width: CGFloat(maxX - minX + 1) / CGFloat(scale),
                      height: CGFloat(maxY - minY + 1) / CGFloat(scale))
    }

    /// Template images render flat black when drawn by hand; tint per draw so the
    /// glyph follows light/dark.
    private func tint(_ image: NSImage) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            NSColor.secondaryLabelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateCount() {
        if let info = matchInfo, info.total > 0, !stringValue.isEmpty {
            countLabel.stringValue = info.current.map { "\($0 + 1) of \(info.total)" } ?? "\(info.total)"
            countLabel.sizeToFit()
            countLabel.isHidden = false
            (cell as? CountingSearchFieldCell)?.countWidth = countLabel.frame.width + 10
        } else {
            countLabel.isHidden = true
            (cell as? CountingSearchFieldCell)?.countWidth = 0
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !countLabel.isHidden else { return }
        let cancel = (cell as? NSSearchFieldCell)?.cancelButtonRect(forBounds: bounds) ?? .zero
        let rightEdge = cancel.width > 0 ? cancel.minX : bounds.maxX - 6
        let w = countLabel.frame.width
        countLabel.frame = NSRect(x: rightEdge - w - 4,
                                  y: (bounds.height - countLabel.frame.height) / 2,
                                  width: w, height: countLabel.frame.height)
    }
}

// MARK: - Segmented control whose segments are individually Tab-reachable

/// AppKit already focuses segments one at a time — it draws the focus ring
/// around a single segment and moves it with ← / → — but Tab always leaves the
/// whole control, so a trailing segment (`›`, `All`) can never be reached by
/// Tab. This translates Tab into AppKit's own arrow handling until the last
/// segment, then releases it to the key-view loop.
///
/// The focused segment has no public accessor, so it is mirrored here: seeded
/// on focus, advanced when we forward an arrow, and kept in sync by watching
/// the user's own ← / → presses.
private final class SegmentTabbingControl: NSSegmentedControl {
    private var focusedSegment = 0

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // AppKit enters on the leading segment going forwards and the *trailing*
        // one coming back via Shift-Tab; seed the mirror to match, or the first
        // Shift-Tab inside the control leaves it a segment early.
        if accepted { focusedSegment = enteringBackwards ? segmentCount - 1 : 0 }
        return accepted
    }

    private var enteringBackwards: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return Int(event.keyCode) == 48 && event.modifierFlags.contains(.shift)
    }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case 48:                                    // Tab / Shift-Tab
            let step = shift ? -1 : 1
            let next = focusedSegment + step
            if (0..<segmentCount).contains(next) {
                focusedSegment = next
                super.keyDown(with: arrowEvent(right: !shift, like: event))
            } else if shift {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
        case 123, 124:                              // ← / → — mirror AppKit's move
            focusedSegment = max(0, min(segmentCount - 1,
                                        focusedSegment + (event.keyCode == 124 ? 1 : -1)))
            super.keyDown(with: event)
        default:
            super.keyDown(with: event)
        }
    }

    private func arrowEvent(right: Bool, like event: NSEvent) -> NSEvent {
        let key = right ? NSRightArrowFunctionKey : NSLeftArrowFunctionKey
        let chars = String(UnicodeScalar(key)!)
        return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow,
                                modifierFlags: [], timestamp: event.timestamp,
                                windowNumber: event.windowNumber, context: nil,
                                characters: chars, charactersIgnoringModifiers: chars,
                                isARepeat: false, keyCode: right ? 124 : 123) ?? event
    }
}

// MARK: - Find bar

/// The in-document find/replace bar, styled after Apple Notes. Laid out on an
/// `NSGridView` so the search/replace fields share a left edge and the `‹ ›` /
/// `Replace|All` control groups share a left edge. Find-only is one row; toggling
/// Replace reveals a second row and moves **Done** down onto it.
///
/// Dumb view: owns the controls, reports events through closures. All logic is
/// in `FindController`.
final class FindBarView: ChromeBarView, NSSearchFieldDelegate {

    let searchField = CountingSearchField()
    let replaceField = NSTextField()

    private let nav = SegmentTabbingControl(
        images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous")!,
                 NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next")!],
        trackingMode: .momentary, target: nil, action: nil)
    private let replaceToggle = NSButton(checkboxWithTitle: "Replace", target: nil, action: nil)
    private let replaceGroup = SegmentTabbingControl(
        labels: ["Replace", "All"], trackingMode: .momentary, target: nil, action: nil)
    // Two Done buttons — one per row — toggled by visibility. Simpler and more
    // robust than moving a single button between grid cells (which failed to
    // render). find-only shows the top one; replace shows the bottom one.
    private let doneTop = NSButton(title: "Done", target: nil, action: nil)
    private let doneBottom = NSButton(title: "Done", target: nil, action: nil)
    /// Row-1 right cluster: Replace|All — spacer — Done.
    private let bottomRightStack = NSStackView()
    /// Row-0 slack, live only in replace mode — see `showsReplaceRow`.
    private let topSpacer = NSView()
    private var grid: NSGridView!

    // Event callbacks, wired by the controller.
    var onSearchChanged: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onDone: (() -> Void)?
    var onToggleReplace: ((Bool) -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    var onOptionsChanged: (() -> Void)?
    /// ⌘F / ⌥⌘F pressed while the bar has focus; the flag is `replace`.
    var onToggleFindBar: ((Bool) -> Void)?

    var caseSensitive = false { didSet { syncOptionMenu() } }
    var wholeWord = false { didSet { syncOptionMenu() } }

    var showsReplaceRow: Bool {
        get { !grid.row(at: 1).isHidden }
        set {
            replaceToggle.state = newValue ? .on : .off
            grid.row(at: 1).isHidden = !newValue   // hides the replace field + right cluster
            doneTop.isHidden = newValue            // Done lives on the visible row only
            // With Done gone the top row has slack: let the spacer take it so
            // Replace lands on the trailing edge, above Done. In find-only there
            // is nothing to absorb, so the cell hugs its content instead.
            topSpacer.isHidden = !newValue
            grid.cell(atColumnIndex: 1, rowIndex: 0).xPlacement = newValue ? .fill : .leading
            refreshKeyViewLoop()
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // AppKit rebuilds the window's key-view loop from view geometry whenever
        // the view tree changes, wiping any `nextKeyView` we set — Tab then fell
        // straight out of the bar. Opt the window out so our chain survives.
        window?.autorecalculatesKeyViewLoop = false
        refreshKeyViewLoop()
    }

    /// Chains the bar's controls into a closed Tab loop in visual order, so Tab
    /// walks the bar instead of escaping to the editor. Rebuilt whenever the
    /// replace row appears or hides, because that changes both the membership
    /// (the replace row joins) and which **Done** is live.
    ///
    /// The loop is declared in full, including the buttons: AppKit skips links
    /// whose view can't become a key view, so with macOS "Keyboard navigation"
    /// off — the default — Tab moves between the two text fields only, and the
    /// same chain lights up the buttons for users who switch it on. Nothing here
    /// can force that; a control's `refusesFirstResponder` doesn't override the
    /// system setting.
    private func refreshKeyViewLoop() {
        let chain: [NSView] = showsReplaceRow
            ? [searchField, nav, replaceToggle, replaceField, replaceGroup, doneBottom]
            : [searchField, nav, doneTop, replaceToggle]
        for (view, next) in zip(chain, chain.dropFirst() + [chain[0]]) {
            view.nextKeyView = next
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
        showsReplaceRow = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Build

    private func buildUI() {
        searchField.placeholderString = "Find"
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        searchField.searchMenuTemplate = optionsMenu()
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        replaceField.placeholderString = "Replace"
        replaceField.bezelStyle = .roundedBezel   // rounded + built-in left padding, matching the search field
        replaceField.target = self
        replaceField.action = #selector(replaceReturn)
        replaceField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        nav.target = self
        nav.action = #selector(navClicked)

        replaceGroup.target = self
        replaceGroup.action = #selector(replaceGroupClicked)
        replaceGroup.segmentDistribution = .fit

        for done in [doneTop, doneBottom] {
            done.bezelStyle = .rounded
            done.target = self
            done.action = #selector(doneClicked)
        }

        replaceToggle.target = self
        replaceToggle.action = #selector(replaceToggled)

        // MARK: - Grid layout
        // A 2×2 grid: column 0 holds the two fields (stretch to fill), column 1
        // the two right-hand clusters. Row 1 (replace) is hidden in find-only.

        // Top cluster: nav, spacer, Done (find-only), Replace. nav is leading, so
        // it shares its left edge with Replace|All below. The spacer is hidden in
        // find-only — there the three controls are evenly spaced — and shown once
        // doneTop detaches for the replace row, pushing Replace out to the
        // trailing edge above Done.
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let topRight = NSStackView(views: [nav, topSpacer, doneTop, replaceToggle])
        topRight.orientation = .horizontal
        topRight.spacing = 8
        topRight.alignment = .centerY

        // Bottom cluster: Replace|All, Done — leading, no spacer, so Replace|All
        // shares the nav's left edge.
        bottomRightStack.orientation = .horizontal
        bottomRightStack.spacing = 8
        bottomRightStack.alignment = .centerY
        bottomRightStack.setViews([replaceGroup, doneBottom], in: .leading)

        grid = NSGridView(views: [
            [searchField, topRight],
            [replaceField, bottomRightStack],
        ])
        grid.columnSpacing = 8
        grid.rowSpacing = 3          // tight gap between the find and replace rows
        grid.column(at: 0).xPlacement = .fill        // fields stretch to fill
        grid.column(at: 1).xPlacement = .leading      // col1 hugs content (driven by the wider cluster)
        grid.row(at: 0).yPlacement = .center
        grid.row(at: 1).yPlacement = .center

        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        replaceField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func optionsMenu() -> NSMenu {
        let menu = NSMenu()
        let cs = NSMenuItem(title: "Case Sensitive", action: #selector(toggleCase), keyEquivalent: "")
        cs.target = self
        let ww = NSMenuItem(title: "Whole Words", action: #selector(toggleWholeWord), keyEquivalent: "")
        ww.target = self
        menu.addItem(cs); menu.addItem(ww)
        return menu
    }

    private func syncOptionMenu() {
        guard let menu = searchField.searchMenuTemplate else { return }
        menu.items.first { $0.action == #selector(toggleCase) }?.state = caseSensitive ? .on : .off
        menu.items.first { $0.action == #selector(toggleWholeWord) }?.state = wholeWord ? .on : .off
    }

    // MARK: - Display

    func setCount(current: Int?, total: Int) {
        searchField.matchInfo = (current, total)
    }

    // MARK: - Search-field Return → find next / ⇧Return → find previous

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField else { return false }
        // ⇧Return arrives as either selector depending on the field's state, and
        // only the originating event carries the modifier.
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if backwards { onPrevious?() } else { onNext?() }
            return true
        default:
            return false
        }
    }

    // MARK: - Find commands while the bar has focus
    //
    // The Edit ▸ Find items target the first responder, and route to
    // `EditorTextView`. With focus inside the bar the editor is not in the
    // responder chain — the bar is — so ⌘F / ⌥⌘F / ⌘G / ⇧⌘G would grey out
    // exactly while you're typing a query. Same selectors here pick them up.

    @objc func showFindBar(_ sender: Any?) { onToggleFindBar?(false) }
    @objc func showFindReplaceBar(_ sender: Any?) { onToggleFindBar?(true) }
    @objc func findNext(_ sender: Any?) { onNext?() }
    @objc func findPrevious(_ sender: Any?) { onPrevious?() }
    @objc func hideFindBar(_ sender: Any?) { onDone?() }

    // MARK: - Actions

    @objc private func searchChanged() { onSearchChanged?() }
    @objc private func doneClicked() { onDone?() }
    @objc private func replaceReturn() { onReplace?() }

    @objc private func navClicked() {
        if nav.selectedSegment == 0 { onPrevious?() } else { onNext?() }
    }

    @objc private func replaceGroupClicked() {
        if replaceGroup.selectedSegment == 0 { onReplace?() } else { onReplaceAll?() }
    }

    @objc private func replaceToggled() {
        showsReplaceRow = replaceToggle.state == .on
        onToggleReplace?(showsReplaceRow)
    }

    @objc private func toggleCase() { caseSensitive.toggle(); onOptionsChanged?() }
    @objc private func toggleWholeWord() { wholeWord.toggle(); onOptionsChanged?() }
}

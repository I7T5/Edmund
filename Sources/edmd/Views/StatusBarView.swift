import AppKit
import EdmundCore

// MARK: - Status Bar View

/// Floating status bar. Hidden by default and revealed when the pointer enters
/// its strip (or pinned visible / hidden outright from the View menu). It draws
/// everything itself — a vertical gradient from the editor background fading to
/// transparent under a hairline, the enabled document-count fields on the left,
/// and the line ending on the right — so there are no subviews to truncate the
/// text.
final class StatusBarView: NSView {

    static let labelFont = NSFont.systemFont(ofSize: 11)

    private var prefs = StatusBarPrefs.load()

    // Latest metrics pushed from the document.
    private var words = 0
    private var characters = 0
    private var location = 0
    private var lineNumber = 1
    private var lineEnding = "LF"

    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = shouldBeVisible ? 1 : 0
        NotificationCenter.default.addObserver(self, selector: #selector(prefsDidChange),
                                               name: StatusBarPrefs.didChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Data

    func setMetrics(words: Int, characters: Int, location: Int, line: Int, lineEnding: String) {
        self.words = words
        self.characters = characters
        self.location = location
        self.lineNumber = line
        self.lineEnding = lineEnding
        needsDisplay = true
    }

    // MARK: - Visibility

    private var shouldBeVisible: Bool { prefs.isShown && (!prefs.autoHide || isHovering) }

    /// Another window's bar, or the View menu, saved new prefs.
    @objc private func prefsDidChange() {
        prefs = StatusBarPrefs.load()
        refreshVisibility(animated: true)
        needsDisplay = true
    }

    private func refreshVisibility(animated: Bool) {
        let target: CGFloat = shouldBeVisible ? 1 : 0
        guard abs(alphaValue - target) > 0.001 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().alphaValue = target
            }
        } else {
            alphaValue = target
        }
    }

    // MARK: - Hover Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeInActiveApp],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        refreshVisibility(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        refreshVisibility(animated: true)
    }

    /// When the bar is hidden, let clicks fall through to the text view beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if !shouldBeVisible && alphaValue < 0.01 { return nil }
        return super.hitTest(point)
    }

    // MARK: - Context Menu (double- or right-click)

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(buildMenu(), with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            NSMenu.popUpContextMenu(buildMenu(), with: event, for: self)
        } else {
            super.mouseDown(with: event)
        }
    }

    private func buildMenu() -> NSMenu {
        // Showing and auto-hiding the bar live in the View menu, beside the
        // toolbar's equivalents; only the field choice is here.
        let menu = NSMenu()
        let header = NSMenuItem(title: "Show Fields", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let fields: [(title: String, key: String, on: Bool)] = [
            ("Words", "words", prefs.showWords),
            ("Characters", "characters", prefs.showCharacters),
            ("Location", "location", prefs.showLocation),
            ("Line", "line", prefs.showLine),
            ("Line Ending", "lineEnding", prefs.showLineEnding),
        ]
        for field in fields {
            let item = NSMenuItem(title: field.title,
                                  action: #selector(toggleField(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = field.key
            item.state = field.on ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleField(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "words":      prefs.showWords.toggle()
        case "characters": prefs.showCharacters.toggle()
        case "location":   prefs.showLocation.toggle()
        case "line":       prefs.showLine.toggle()
        case "lineEnding": prefs.showLineEnding.toggle()
        default: return
        }
        prefs.save()   // redraws via prefsDidChange
    }

    // MARK: - Drawing

    private var labelAttrs: [NSAttributedString.Key: Any] {
        [.font: Self.labelFont, .foregroundColor: NSColor.secondaryLabelColor]
    }
    private var valueAttrs: [NSAttributedString.Key: Any] {
        [.font: Self.labelFont, .foregroundColor: NSColor.labelColor]
    }

    override func draw(_ dirtyRect: NSRect) {
        // Vertical gradient: the editor background, fully opaque at the bottom and
        // softening only slightly toward the top so the bar reads clearly even
        // when overlaid on text. textBackgroundColor is semantic (light/dark).
        let base = NSColor.textBackgroundColor
        if let gradient = NSGradient(starting: base, ending: base.withAlphaComponent(0.85)) {
            gradient.draw(in: bounds, angle: 90)   // 90° = bottom → top
        }
        // Top hairline, as CotEditor's and Xcode's status bars have: one device
        // pixel, filled (a stroke straddles two), in the separator colour the
        // toolbar and chrome bars use.
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - pixel, width: bounds.width, height: pixel).fill()

        let hMargin: CGFloat = 12

        // Left: enabled count fields ("Label: value", label dimmed, value bold-ish).
        let info = NSMutableAttributedString()
        func field(_ name: String, _ value: String) {
            if info.length > 0 {
                info.append(NSAttributedString(string: "   ", attributes: labelAttrs))
            }
            info.append(NSAttributedString(string: "\(name): ", attributes: labelAttrs))
            info.append(NSAttributedString(string: value, attributes: valueAttrs))
        }
        if prefs.showWords      { field("Words", "\(words)") }
        if prefs.showCharacters { field("Characters", "\(characters)") }
        if prefs.showLocation   { field("Location", "\(location)") }
        if prefs.showLine       { field("Line", "\(lineNumber)") }

        if info.length > 0 {
            let size = info.size()
            info.draw(at: NSPoint(x: hMargin, y: (bounds.height - size.height) / 2))
        }

        // Right: line ending, preceded by a short vertical divider.
        if prefs.showLineEnding {
            let value = NSAttributedString(string: lineEnding, attributes: valueAttrs)
            let size = value.size()
            let x = bounds.maxX - hMargin - size.width
            value.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))

            if info.length > 0 {
                NSColor.separatorColor.setStroke()
                let dx = round(x - 12) + 0.5
                let divider = NSBezierPath()
                divider.move(to: NSPoint(x: dx, y: 5))
                divider.line(to: NSPoint(x: dx, y: bounds.height - 5))
                divider.lineWidth = 1
                divider.stroke()
            }
        }
    }
}

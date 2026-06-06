import AppKit
import CoreText
import MarkdownEditorCore

/// The Settings window (⌘,). Lets the user pick the body font and size, accent
/// and code colors, and line / paragraph spacing, with a live preview. Changes
/// are written into an `EditorTheme`, persisted, and applied to every open
/// editor so the document updates immediately.
class SettingsWindowController: NSWindowController {

    private var fontPopup: NSPopUpButton!
    private var sizeField: NSTextField!
    private var sizeStepper: NSStepper!
    private var previewLabel: NSTextField!
    private var accentColorWell: NSColorWell!
    private var codeColorWell: NSColorWell!
    private var lineSpacingField: NSTextField!
    private var lineSpacingStepper: NSStepper!
    private var paragraphSpacingField: NSTextField!
    private var paragraphSpacingStepper: NSStepper!

    /// All open editor views get updated when settings change.
    private var fontFamilies: [String] = []

    /// Builds a complete list of font families by scanning system font
    /// directories. `NSFontManager.availableFontFamilies` omits fonts in
    /// `/System/Library/Fonts/Supplemental/` (Athelas, Iowan Old Style, etc.).
    private static func allInstalledFontFamilies() -> [String] {
        var families = Set(NSFontManager.shared.availableFontFamilies)

        let fontDirs = [
            "/System/Library/Fonts",
            "/System/Library/Fonts/Supplemental",
            "/Library/Fonts",
            NSString("~/Library/Fonts").expandingTildeInPath,
        ]
        let fontExtensions: Set<String> = ["ttf", "ttc", "otf", "dfont"]
        let fm = FileManager.default

        for dir in fontDirs {
            guard let enumerator = fm.enumerator(atPath: dir) else { continue }
            while let file = enumerator.nextObject() as? String {
                let ext = (file as NSString).pathExtension.lowercased()
                guard fontExtensions.contains(ext) else { continue }
                let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
                if let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
                    for d in descs {
                        if let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String {
                            families.insert(family)
                        }
                    }
                }
            }
        }

        return families.sorted()
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        setupUI()
        loadCurrentSettings()
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let margin: CGFloat = 20
        let labelWidth: CGFloat = 100
        let rowHeight: CGFloat = 26
        let spacing: CGFloat = 14

        var y: CGFloat = 290

        // --- Row 1: Font Family ---
        addLabel("Font:", at: NSPoint(x: margin, y: y), width: labelWidth, in: contentView)

        fontFamilies = Self.allInstalledFontFamilies()

        fontPopup = NSPopUpButton(frame: NSRect(x: margin + labelWidth + 8, y: y, width: 220, height: rowHeight), pullsDown: false)
        fontPopup.addItems(withTitles: fontFamilies)
        fontPopup.target = self
        fontPopup.action = #selector(settingChanged(_:))
        contentView.addSubview(fontPopup)

        // --- Row 2: Font Size ---
        y -= rowHeight + spacing
        addLabel("Size:", at: NSPoint(x: margin, y: y), width: labelWidth, in: contentView)

        sizeField = NSTextField(frame: NSRect(x: margin + labelWidth + 8, y: y, width: 60, height: rowHeight))
        sizeField.formatter = intFormatter(min: 8, max: 72)
        sizeField.target = self
        sizeField.action = #selector(sizeFieldChanged(_:))
        contentView.addSubview(sizeField)

        sizeStepper = NSStepper(frame: NSRect(x: margin + labelWidth + 8 + 64, y: y, width: 19, height: rowHeight))
        sizeStepper.minValue = 8
        sizeStepper.maxValue = 72
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeStepperChanged(_:))
        contentView.addSubview(sizeStepper)

        // --- Row 3: Accent Color ---
        y -= rowHeight + spacing
        addLabel("Accent color:", at: NSPoint(x: margin, y: y), width: labelWidth, in: contentView)

        accentColorWell = NSColorWell(frame: NSRect(x: margin + labelWidth + 8, y: y, width: 44, height: rowHeight))
        accentColorWell.target = self
        accentColorWell.action = #selector(settingChanged(_:))
        contentView.addSubview(accentColorWell)

        // --- Row 4: Code Color ---
        y -= rowHeight + spacing
        addLabel("Code color:", at: NSPoint(x: margin, y: y), width: labelWidth, in: contentView)

        codeColorWell = NSColorWell(frame: NSRect(x: margin + labelWidth + 8, y: y, width: 44, height: rowHeight))
        codeColorWell.target = self
        codeColorWell.action = #selector(settingChanged(_:))
        contentView.addSubview(codeColorWell)

        // --- Row 5: Line Spacing ---
        y -= rowHeight + spacing
        addLabel("Line spacing:", at: NSPoint(x: margin, y: y), width: labelWidth, in: contentView)

        lineSpacingField = NSTextField(frame: NSRect(x: margin + labelWidth + 8, y: y, width: 60, height: rowHeight))
        lineSpacingField.formatter = floatFormatter(min: 0, max: 20)
        lineSpacingField.target = self
        lineSpacingField.action = #selector(lineSpacingFieldChanged(_:))
        contentView.addSubview(lineSpacingField)

        lineSpacingStepper = NSStepper(frame: NSRect(x: margin + labelWidth + 8 + 64, y: y, width: 19, height: rowHeight))
        lineSpacingStepper.minValue = 0
        lineSpacingStepper.maxValue = 20
        lineSpacingStepper.increment = 1
        lineSpacingStepper.valueWraps = false
        lineSpacingStepper.target = self
        lineSpacingStepper.action = #selector(lineSpacingStepperChanged(_:))
        contentView.addSubview(lineSpacingStepper)

        // --- Row 6: Paragraph Spacing ---
        y -= rowHeight + spacing
        addLabel("Para spacing:", at: NSPoint(x: margin, y: y), width: labelWidth, in: contentView)

        paragraphSpacingField = NSTextField(frame: NSRect(x: margin + labelWidth + 8, y: y, width: 60, height: rowHeight))
        paragraphSpacingField.formatter = floatFormatter(min: 0, max: 20)
        paragraphSpacingField.target = self
        paragraphSpacingField.action = #selector(paragraphSpacingFieldChanged(_:))
        contentView.addSubview(paragraphSpacingField)

        paragraphSpacingStepper = NSStepper(frame: NSRect(x: margin + labelWidth + 8 + 64, y: y, width: 19, height: rowHeight))
        paragraphSpacingStepper.minValue = 0
        paragraphSpacingStepper.maxValue = 20
        paragraphSpacingStepper.increment = 1
        paragraphSpacingStepper.valueWraps = false
        paragraphSpacingStepper.target = self
        paragraphSpacingStepper.action = #selector(paragraphSpacingStepperChanged(_:))
        contentView.addSubview(paragraphSpacingStepper)

        // --- Row 7: Preview ---
        y -= rowHeight + spacing
        previewLabel = NSTextField(labelWithString: "The quick brown fox jumps over the lazy dog.")
        previewLabel.frame = NSRect(x: margin + labelWidth + 8, y: y, width: 280, height: rowHeight)
        previewLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(previewLabel)
    }

    // MARK: - Helpers

    @discardableResult
    private func addLabel(_ text: String, at origin: NSPoint, width: CGFloat, in view: NSView) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: origin.x, y: origin.y, width: width, height: 26)
        label.alignment = .right
        view.addSubview(label)
        return label
    }

    private func intFormatter(min: Int, max: Int) -> NumberFormatter {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimum = NSNumber(value: min)
        nf.maximum = NSNumber(value: max)
        nf.maximumFractionDigits = 0
        return nf
    }

    private func floatFormatter(min: Double, max: Double) -> NumberFormatter {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimum = NSNumber(value: min)
        nf.maximum = NSNumber(value: max)
        nf.maximumFractionDigits = 1
        return nf
    }

    // MARK: - Load Current Settings

    private func loadCurrentSettings() {
        let theme = EditorTheme.load()

        // Font family — resolve PostScript name to family
        let family = fontFamilies.first { fam in
            fam == theme.fontName || (NSFont(name: theme.fontName, size: 12)?.familyName == fam)
        } ?? theme.fontName

        if let idx = fontFamilies.firstIndex(of: family) {
            fontPopup.selectItem(at: idx)
        }
        sizeField.integerValue = Int(theme.fontSize)
        sizeStepper.doubleValue = Double(theme.fontSize)

        accentColorWell.color = theme.accentColor
        codeColorWell.color = theme.codeColor

        lineSpacingField.doubleValue = Double(theme.lineSpacing)
        lineSpacingStepper.doubleValue = Double(theme.lineSpacing)

        paragraphSpacingField.doubleValue = Double(theme.paragraphSpacingBefore)
        paragraphSpacingStepper.doubleValue = Double(theme.paragraphSpacingBefore)

        updatePreview()
    }

    // MARK: - Actions

    @objc private func settingChanged(_ sender: Any?) {
        applyTheme()
    }

    @objc private func sizeFieldChanged(_ sender: NSTextField) {
        let size = max(8, min(72, sender.integerValue))
        sizeStepper.doubleValue = Double(size)
        sizeField.integerValue = size
        applyTheme()
    }

    @objc private func sizeStepperChanged(_ sender: NSStepper) {
        sizeField.integerValue = Int(sender.doubleValue)
        applyTheme()
    }

    @objc private func lineSpacingFieldChanged(_ sender: NSTextField) {
        let val = max(0, min(20, sender.doubleValue))
        lineSpacingStepper.doubleValue = val
        lineSpacingField.doubleValue = val
        applyTheme()
    }

    @objc private func lineSpacingStepperChanged(_ sender: NSStepper) {
        lineSpacingField.doubleValue = sender.doubleValue
        applyTheme()
    }

    @objc private func paragraphSpacingFieldChanged(_ sender: NSTextField) {
        let val = max(0, min(20, sender.doubleValue))
        paragraphSpacingStepper.doubleValue = val
        paragraphSpacingField.doubleValue = val
        applyTheme()
    }

    @objc private func paragraphSpacingStepperChanged(_ sender: NSStepper) {
        paragraphSpacingField.doubleValue = sender.doubleValue
        applyTheme()
    }

    // MARK: - Apply

    private func applyTheme() {
        guard let family = fontPopup.titleOfSelectedItem else { return }

        // Resolve family name to a usable font name
        let fontName: String
        if let members = NSFontManager.shared.availableMembers(ofFontFamily: family),
           let first = members.first,
           let postscriptName = first[0] as? String {
            fontName = postscriptName
        } else {
            fontName = family
        }

        let theme = EditorTheme(
            fontName: fontName,
            fontSize: CGFloat(sizeField.integerValue),
            accentHex: accentColorWell.color.hexString,
            codeHex: codeColorWell.color.hexString,
            lineSpacing: CGFloat(lineSpacingField.doubleValue),
            paragraphSpacingBefore: CGFloat(paragraphSpacingField.doubleValue)
        )

        updatePreview()

        // Update all open editor views
        for document in NSDocumentController.shared.documents {
            if let doc = document as? Document {
                doc.editor?.applyTheme(theme)
            }
        }
    }

    private func updatePreview() {
        guard let family = fontPopup.titleOfSelectedItem else { return }
        let size = CGFloat(sizeField.integerValue)
        if let font = NSFont(name: family, size: size) {
            previewLabel.font = font
        } else if let members = NSFontManager.shared.availableMembers(ofFontFamily: family),
                  let first = members.first,
                  let postscriptName = first[0] as? String,
                  let font = NSFont(name: postscriptName, size: size) {
            previewLabel.font = font
        }
    }
}

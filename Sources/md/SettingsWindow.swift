import AppKit
import MarkdownEditorCore

enum AppSettings {
    enum StartupAction: String {
        case createNewDocument
        case doNothing
    }

    enum ConflictResolution: String {
        case keepCurrent
        case ask
        case updateToModified
    }

    enum AppearanceMode: String {
        case matchSystem
        case light
        case dark
    }

    private enum Key {
        static let reopenWindows = "settings.general.reopenWindows"
        static let startupAction = "settings.general.startupAction"
        static let autoSaveWithVersions = "settings.general.autoSaveWithVersions"
        static let conflictResolution = "settings.general.conflictResolution"
        static let standardAntialias = "settings.appearance.standardAntialias"
        static let standardLigatures = "settings.appearance.standardLigatures"
        static let monospaceFontName = "settings.appearance.monospaceFontName"
        static let monospaceFontSize = "settings.appearance.monospaceFontSize"
        static let monospaceAntialias = "settings.appearance.monospaceAntialias"
        static let monospaceLigatures = "settings.appearance.monospaceLigatures"
        static let appearanceMode = "settings.appearance.mode"
    }

    static var reopenWindows: Bool {
        get { UserDefaults.standard.bool(forKey: Key.reopenWindows) }
        set { UserDefaults.standard.set(newValue, forKey: Key.reopenWindows) }
    }

    static var startupAction: StartupAction {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.startupAction),
                  let action = StartupAction(rawValue: raw) else {
                return .createNewDocument
            }
            return action
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.startupAction) }
    }

    static var autoSaveWithVersions: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.autoSaveWithVersions) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.autoSaveWithVersions)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.autoSaveWithVersions) }
    }

    static var conflictResolution: ConflictResolution {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.conflictResolution),
                  let resolution = ConflictResolution(rawValue: raw) else {
                return .ask
            }
            return resolution
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.conflictResolution) }
    }

    static var standardAntialias: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.standardAntialias) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.standardAntialias)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.standardAntialias) }
    }

    static var standardLigatures: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.standardLigatures) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.standardLigatures)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.standardLigatures) }
    }

    static var monospaceFontName: String {
        get {
            UserDefaults.standard.string(forKey: Key.monospaceFontName)
                ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).fontName
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.monospaceFontName) }
    }

    static var monospaceFontSize: CGFloat {
        get {
            let size = CGFloat(UserDefaults.standard.float(forKey: Key.monospaceFontSize))
            return size > 0 ? size : 14
        }
        set { UserDefaults.standard.set(Float(newValue), forKey: Key.monospaceFontSize) }
    }

    static var monospaceAntialias: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.monospaceAntialias) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.monospaceAntialias)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.monospaceAntialias) }
    }

    static var monospaceLigatures: Bool {
        get { UserDefaults.standard.bool(forKey: Key.monospaceLigatures) }
        set { UserDefaults.standard.set(newValue, forKey: Key.monospaceLigatures) }
    }

    static var appearanceMode: AppearanceMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.appearanceMode),
                  let mode = AppearanceMode(rawValue: raw) else {
                return .matchSystem
            }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.appearanceMode) }
    }

    @MainActor static func applyAppearance() {
        switch appearanceMode {
        case .matchSystem:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// A CotEditor-style Settings window with the currently supported General and
/// Appearance panes.
class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private enum Pane {
        case general
        case appearance

        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            }
        }

        var identifier: NSToolbarItem.Identifier {
            switch self {
            case .general: return Self.generalIdentifier
            case .appearance: return Self.appearanceIdentifier
            }
        }

        static let generalIdentifier = NSToolbarItem.Identifier("settings.general")
        static let appearanceIdentifier = NSToolbarItem.Identifier("settings.appearance")
    }

    private enum FontPanelTarget {
        case standard
        case monospace
    }

    private let contentWidth: CGFloat = 760
    private var selectedPane: Pane = .general
    private var contentContainer: NSView!

    private var reopenWindowsCheckbox: NSButton!
    private var startupPopup: NSPopUpButton!
    private var autoSaveCheckbox: NSButton!
    private var keepCurrentRadio: NSButton!
    private var askRadio: NSButton!
    private var updateModifiedRadio: NSButton!

    private var standardFontField: NSTextField!
    private var standardSizeStepper: NSStepper!
    private var standardAntialiasCheckbox: NSButton!
    private var standardLigaturesCheckbox: NSButton!
    private var monospaceFontField: NSTextField!
    private var monospaceSizeStepper: NSStepper!
    private var monospaceAntialiasCheckbox: NSButton!
    private var monospaceLigaturesCheckbox: NSButton!
    private var lineHeightField: NSTextField!
    private var lineHeightStepper: NSStepper!
    private var matchSystemRadio: NSButton!
    private var lightRadio: NSButton!
    private var darkRadio: NSButton!

    private var currentTheme = EditorTheme.load()
    private var standardFont: NSFont
    private var monospaceFont: NSFont
    private var fontPanelTarget: FontPanelTarget = .standard

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "General"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        setupWindow()
        showPane(.general, animate: false)
    }

    override init(window: NSWindow?) {
        let theme = EditorTheme.load()
        standardFont = theme.bodyFont
        monospaceFont = NSFont(
            name: AppSettings.monospaceFontName,
            size: AppSettings.monospaceFontSize
        ) ?? .monospacedSystemFont(ofSize: AppSettings.monospaceFontSize, weight: .regular)
        currentTheme = theme
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        let theme = EditorTheme.load()
        standardFont = theme.bodyFont
        monospaceFont = NSFont(
            name: AppSettings.monospaceFontName,
            size: AppSettings.monospaceFontSize
        ) ?? .monospacedSystemFont(ofSize: AppSettings.monospaceFontSize, weight: .regular)
        currentTheme = theme
        super.init(coder: coder)
    }

    private func setupWindow() {
        guard let window else { return }

        contentContainer = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 360))
        contentContainer.autoresizesSubviews = true
        window.contentView = contentContainer
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .line

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = Pane.generalIdentifier
        window.toolbar = toolbar
        window.toolbarStyle = .preference
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Pane.generalIdentifier, Pane.appearanceIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self
        item.action = #selector(selectPane(_:))

        switch itemIdentifier {
        case Pane.generalIdentifier:
            item.label = "General"
            item.paletteLabel = "General"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        case Pane.appearanceIdentifier:
            item.label = "Appearance"
            item.paletteLabel = "Appearance"
            item.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "Appearance")
        default:
            return nil
        }

        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        switch sender.itemIdentifier {
        case Pane.generalIdentifier:
            showPane(.general, animate: true)
        case Pane.appearanceIdentifier:
            showPane(.appearance, animate: true)
        default:
            break
        }
    }

    private func showPane(_ pane: Pane, animate: Bool) {
        selectedPane = pane
        window?.title = pane.title
        window?.toolbar?.selectedItemIdentifier = pane.identifier

        let pad: CGFloat = 20
        let helpRow: CGFloat = 36
        let grid = pane == .general ? makeGeneralPane() : makeAppearancePane()
        grid.layoutSubtreeIfNeeded()
        let gridSize = grid.fittingSize
        let size = NSSize(width: max(520, gridSize.width + pad * 2),
                          height: gridSize.height + pad * 2 + helpRow)
        resizeContent(to: size, animate: animate)

        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        grid.frame = NSRect(x: pad, y: size.height - pad - gridSize.height,
                            width: gridSize.width, height: gridSize.height)
        grid.autoresizingMask = [.maxXMargin, .minYMargin]
        contentContainer.addSubview(grid)
        addHelpButton(to: contentContainer)
    }

    private func resizeContent(to size: NSSize, animate: Bool) {
        guard let window else { return }
        let oldFrame = window.frame
        let newFrameRect = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let newFrame = NSRect(
            x: oldFrame.origin.x,
            y: oldFrame.maxY - newFrameRect.height,
            width: newFrameRect.width,
            height: newFrameRect.height
        )
        window.setFrame(newFrame, display: true, animate: animate)
        contentContainer.frame = NSRect(origin: .zero, size: size)
    }

    // MARK: - General Pane

    private func makeGeneralPane() -> NSGridView {
        // On startup
        reopenWindowsCheckbox = checkbox("Reopen windows from last session",
                                         action: #selector(generalSettingChanged(_:)))
        reopenWindowsCheckbox.state = AppSettings.reopenWindows ? .on : .off

        startupPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        startupPopup.addItem(withTitle: "Create New Document")
        startupPopup.addItem(withTitle: "Do Nothing")
        startupPopup.selectItem(at: AppSettings.startupAction == .createNewDocument ? 0 : 1)
        startupPopup.target = self
        startupPopup.action = #selector(generalSettingChanged(_:))
        let startupStack = vStack([
            reopenWindowsCheckbox,
            plainLabel("When nothing else is open:"),
            indented(startupPopup, by: 20)
        ])

        // Document save
        autoSaveCheckbox = checkbox("Enable Auto Save with Versions",
                                    action: #selector(generalSettingChanged(_:)))
        autoSaveCheckbox.state = AppSettings.autoSaveWithVersions ? .on : .off
        let saveStack = vStack([
            autoSaveCheckbox,
            indented(helpText("A system feature that automatically overwrites your files while editing. Even if turned off, md creates a backup in case it unexpectedly quits."), by: 2)
        ])

        // Document-conflict radios
        keepCurrentRadio = radio("Keep md’s edition", action: #selector(conflictRadioChanged(_:)))
        askRadio = radio("Ask how to resolve", action: #selector(conflictRadioChanged(_:)))
        updateModifiedRadio = radio("Update to modified edition", action: #selector(conflictRadioChanged(_:)))
        refreshConflictRadios()
        let conflictRadios = vStack([keepCurrentRadio, askRadio, updateModifiedRadio])

        // Dialog warnings
        let manageWarnings = NSButton(title: "Manage Warnings…",
                                      target: self, action: #selector(manageWarnings(_:)))
        manageWarnings.bezelStyle = .rounded

        let grid = NSGridView()
        grid.rowSpacing = 18
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.addRow(with: [trailingLabel("On startup:"), startupStack])
        grid.addRow(with: [trailingLabel("Document save:"), saveStack])
        let conflictHeader = grid.numberOfRows
        grid.addRow(with: [plainLabel("When document is changed by another application:"),
                           NSGridCell.emptyContentView])
        grid.addRow(with: [NSGridCell.emptyContentView, conflictRadios])
        grid.addRow(with: [trailingLabel("Dialog warnings:"), manageWarnings])

        grid.column(at: 0).xPlacement = .trailing
        grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2),
                        verticalRange: NSRange(location: conflictHeader, length: 1))
        grid.cell(atColumnIndex: 0, rowIndex: conflictHeader).xPlacement = .leading
        return grid
    }

    @objc private func generalSettingChanged(_ sender: Any?) {
        AppSettings.reopenWindows = reopenWindowsCheckbox.state == .on
        AppSettings.startupAction = startupPopup.indexOfSelectedItem == 0 ? .createNewDocument : .doNothing
        AppSettings.autoSaveWithVersions = autoSaveCheckbox.state == .on
    }

    @objc private func conflictRadioChanged(_ sender: NSButton) {
        if sender == keepCurrentRadio {
            AppSettings.conflictResolution = .keepCurrent
        } else if sender == askRadio {
            AppSettings.conflictResolution = .ask
        } else {
            AppSettings.conflictResolution = .updateToModified
        }
        refreshConflictRadios()
    }

    private func refreshConflictRadios() {
        let resolution = AppSettings.conflictResolution
        keepCurrentRadio.state = resolution == .keepCurrent ? .on : .off
        askRadio.state = resolution == .ask ? .on : .off
        updateModifiedRadio.state = resolution == .updateToModified ? .on : .off
    }

    @objc private func manageWarnings(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "No Dialog Warnings"
        alert.informativeText = "There are no suppressed warnings to manage."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window!)
    }

    // MARK: - Appearance Pane

    private func makeAppearancePane() -> NSGridView {
        // Standard font
        standardFontField = fontDisplayField()
        standardSizeStepper = sizeStepper(value: standardFont.pointSize, action: #selector(standardSizeChanged(_:)))
        let standardSelect = selectFontButton(action: #selector(selectStandardFont(_:)))
        standardAntialiasCheckbox = checkbox("Antialias", action: #selector(appearanceSettingChanged(_:)))
        standardAntialiasCheckbox.state = AppSettings.standardAntialias ? .on : .off
        standardLigaturesCheckbox = checkbox("Ligatures", action: #selector(appearanceSettingChanged(_:)))
        standardLigaturesCheckbox.state = AppSettings.standardLigatures ? .on : .off
        let standardStack = vStack([
            hStack([standardFontField, standardSizeStepper, standardSelect]),
            hStack([standardAntialiasCheckbox, standardLigaturesCheckbox])
        ])

        // Monospaced font
        monospaceFontField = fontDisplayField()
        monospaceSizeStepper = sizeStepper(value: monospaceFont.pointSize, action: #selector(monospaceSizeChanged(_:)))
        let monospaceSelect = selectFontButton(action: #selector(selectMonospaceFont(_:)))
        monospaceAntialiasCheckbox = checkbox("Antialias", action: #selector(appearanceSettingChanged(_:)))
        monospaceAntialiasCheckbox.state = AppSettings.monospaceAntialias ? .on : .off
        monospaceLigaturesCheckbox = checkbox("Ligatures", action: #selector(appearanceSettingChanged(_:)))
        monospaceLigaturesCheckbox.state = AppSettings.monospaceLigatures ? .on : .off
        let monospaceStack = vStack([
            hStack([monospaceFontField, monospaceSizeStepper, monospaceSelect]),
            hStack([monospaceAntialiasCheckbox, monospaceLigaturesCheckbox])
        ])

        // Line height
        lineHeightField = NSTextField()
        lineHeightField.formatter = floatFormatter(min: 1, max: 3)
        lineHeightField.alignment = .right
        lineHeightField.target = self
        lineHeightField.action = #selector(lineHeightFieldChanged(_:))
        lineHeightField.translatesAutoresizingMaskIntoConstraints = false
        lineHeightField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        lineHeightStepper = NSStepper()
        lineHeightStepper.minValue = 1
        lineHeightStepper.maxValue = 3
        lineHeightStepper.increment = 0.1
        lineHeightStepper.target = self
        lineHeightStepper.action = #selector(lineHeightStepperChanged(_:))
        let lineHeightStack = hStack([lineHeightField, lineHeightStepper, plainLabel("times")])

        // Appearance mode
        matchSystemRadio = radio("Match System", action: #selector(appearanceModeChanged(_:)))
        lightRadio = radio("Light", action: #selector(appearanceModeChanged(_:)))
        darkRadio = radio("Dark", action: #selector(appearanceModeChanged(_:)))
        let appearanceStack = hStack([matchSystemRadio, lightRadio, darkRadio])

        let grid = NSGridView()
        grid.rowSpacing = 12
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.addRow(with: [trailingLabel("Standard font:"), standardStack])
        grid.addRow(with: [trailingLabel("Monospaced font:"), monospaceStack])
        grid.addRow(with: [trailingLabel("Line height:"), lineHeightStack])
        grid.addRow(with: [trailingLabel("Appearance:"), appearanceStack])
        grid.column(at: 0).xPlacement = .trailing

        refreshFontFields()
        refreshLineHeight()
        refreshAppearanceRadios()
        return grid
    }

    // MARK: - Grid builders

    private func trailingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private func plainLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func helpText(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.preferredMaxLayoutWidth = 360
        return label
    }

    private func checkbox(_ title: String, action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: action)
    }

    private func radio(_ title: String, action: Selector) -> NSButton {
        NSButton(radioButtonWithTitle: title, target: self, action: action)
    }

    private func fontDisplayField() -> NSTextField {
        let field = NSTextField()
        field.isEditable = false
        field.isSelectable = false
        field.alignment = .center
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 230).isActive = true
        return field
    }

    private func sizeStepper(value: CGFloat, action: Selector) -> NSStepper {
        let stepper = NSStepper()
        stepper.minValue = 8
        stepper.maxValue = 72
        stepper.increment = 1
        stepper.doubleValue = Double(value)
        stepper.target = self
        stepper.action = action
        return stepper
    }

    private func selectFontButton(action: Selector) -> NSButton {
        let button = NSButton(title: "Select…", target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func vStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func hStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        return stack
    }

    private func indented(_ view: NSView, by inset: CGFloat) -> NSView {
        let stack = NSStackView(views: [view])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: 0)
        return stack
    }

    @objc private func selectStandardFont(_ sender: Any?) {
        fontPanelTarget = .standard
        showFontPanel(selectedFont: standardFont)
    }

    @objc private func selectMonospaceFont(_ sender: Any?) {
        fontPanelTarget = .monospace
        showFontPanel(selectedFont: monospaceFont)
    }

    private func showFontPanel(selectedFont: NSFont) {
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(selectedFont, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    @objc private func changeFont(_ sender: NSFontManager) {
        switch fontPanelTarget {
        case .standard:
            standardFont = sender.convert(standardFont)
            standardSizeStepper.doubleValue = Double(standardFont.pointSize)
            applyTheme()
        case .monospace:
            monospaceFont = sender.convert(monospaceFont)
            monospaceSizeStepper.doubleValue = Double(monospaceFont.pointSize)
            AppSettings.monospaceFontName = monospaceFont.fontName
            AppSettings.monospaceFontSize = monospaceFont.pointSize
            refreshFontFields()
        }
    }

    @objc private func standardSizeChanged(_ sender: NSStepper) {
        standardFont = NSFont(descriptor: standardFont.fontDescriptor, size: CGFloat(sender.doubleValue))
            ?? standardFont
        applyTheme()
    }

    @objc private func monospaceSizeChanged(_ sender: NSStepper) {
        monospaceFont = NSFont(descriptor: monospaceFont.fontDescriptor, size: CGFloat(sender.doubleValue))
            ?? monospaceFont
        AppSettings.monospaceFontName = monospaceFont.fontName
        AppSettings.monospaceFontSize = monospaceFont.pointSize
        refreshFontFields()
    }

    @objc private func lineHeightFieldChanged(_ sender: NSTextField) {
        let value = max(1, min(3, sender.doubleValue))
        lineHeightField.doubleValue = value
        lineHeightStepper.doubleValue = value
        applyTheme()
    }

    @objc private func lineHeightStepperChanged(_ sender: NSStepper) {
        lineHeightField.doubleValue = sender.doubleValue
        applyTheme()
    }

    @objc private func appearanceSettingChanged(_ sender: Any?) {
        AppSettings.standardAntialias = standardAntialiasCheckbox.state == .on
        AppSettings.standardLigatures = standardLigaturesCheckbox.state == .on
        AppSettings.monospaceAntialias = monospaceAntialiasCheckbox.state == .on
        AppSettings.monospaceLigatures = monospaceLigaturesCheckbox.state == .on
    }

    @objc private func appearanceModeChanged(_ sender: NSButton) {
        if sender == lightRadio {
            AppSettings.appearanceMode = .light
        } else if sender == darkRadio {
            AppSettings.appearanceMode = .dark
        } else {
            AppSettings.appearanceMode = .matchSystem
        }
        refreshAppearanceRadios()
        AppSettings.applyAppearance()
    }

    private func applyTheme() {
        let lineHeight = CGFloat(lineHeightField?.doubleValue ?? currentLineHeightMultiplier())
        let lineSpacing = max(0, (lineHeight - 1) * standardFont.pointSize)
        let theme = EditorTheme(
            fontName: standardFont.fontName,
            fontSize: standardFont.pointSize,
            accentHex: currentTheme.accentHex,
            codeHex: currentTheme.codeHex,
            lineSpacing: lineSpacing,
            paragraphSpacingBefore: currentTheme.paragraphSpacingBefore,
            mathOperatorHex: currentTheme.mathOperatorHex,
            mathNumberHex: currentTheme.mathNumberHex
        )

        currentTheme = theme
        theme.save()
        for case let document as Document in NSDocumentController.shared.documents {
            document.editor?.applyTheme(theme)
        }

        refreshFontFields()
        refreshLineHeight()
    }

    private func refreshFontFields() {
        standardFontField?.stringValue = fontSummary(standardFont)
        monospaceFontField?.stringValue = fontSummary(monospaceFont)
    }

    private func fontSummary(_ font: NSFont) -> String {
        let name = font.displayName ?? font.familyName ?? font.fontName
        return "\(name)  \(Int(round(font.pointSize)))"
    }

    private func refreshLineHeight() {
        let value = currentLineHeightMultiplier()
        lineHeightField?.doubleValue = Double(value)
        lineHeightStepper?.doubleValue = Double(value)
    }

    private func currentLineHeightMultiplier() -> CGFloat {
        guard standardFont.pointSize > 0 else { return 1 }
        return max(1, min(3, (standardFont.pointSize + currentTheme.lineSpacing) / standardFont.pointSize))
    }

    private func refreshAppearanceRadios() {
        let mode = AppSettings.appearanceMode
        matchSystemRadio.state = mode == .matchSystem ? .on : .off
        lightRadio.state = mode == .light ? .on : .off
        darkRadio.state = mode == .dark ? .on : .off
    }

    // MARK: - Shared Controls

    private func addHelpButton(to view: NSView) {
        let button = NSButton(title: "?", target: self, action: #selector(showHelp(_:)))
        button.bezelStyle = .helpButton
        button.frame = NSRect(x: view.bounds.width - 58, y: 24, width: 32, height: 32)
        button.autoresizingMask = [.minXMargin, .maxYMargin]
        view.addSubview(button)
    }

    @objc private func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "\(selectedPane.title) Settings"
        alert.informativeText = "These settings are saved automatically."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window!)
    }

    private func floatFormatter(min: Double, max: Double) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = NSNumber(value: min)
        formatter.maximum = NSNumber(value: max)
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }
}

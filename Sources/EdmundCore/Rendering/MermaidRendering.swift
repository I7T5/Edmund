import AppKit
import EdmundMermaidBridge

/// A hashable description of the visual inputs sent to BeautifulMermaid. The
/// native `DiagramTheme` contains AppKit objects and is not itself Hashable, so
/// this value is the stable cache identity.
struct MermaidThemeKey: Hashable, Sendable {
    let dark: Bool
    let fontName: String
    let fontSize: CGFloat
    let standardLigatures: Bool
    let accentHex: String
}

struct MermaidRenderStyle: Sendable {
    let key: MermaidThemeKey
    let theme: NativeMermaidTheme

    @MainActor
    init(editorTheme: EditorTheme, dark: Bool) {
        key = MermaidThemeKey(
            dark: dark,
            fontName: editorTheme.fontName,
            fontSize: editorTheme.fontSize,
            standardLigatures: editorTheme.standardLigatures,
            accentHex: editorTheme.linkBlueHex
        )
        theme = NativeMermaidTheme(
            background: NSColor(hex: dark ? "#292929" : "#ffffff") ?? .textBackgroundColor,
            foreground: NSColor(hex: dark ? "#e6e6e6" : "#1a1a1a") ?? .textColor,
            accent: NSColor(hex: editorTheme.linkBlueHex) ?? .systemBlue,
            font: editorTheme.bodyFont
        )
    }
}

private actor MermaidRenderWorker {
    static let shared = MermaidRenderWorker()

    func image(source: String, theme: NativeMermaidTheme) -> NSImage? {
        guard !Task.isCancelled else { return nil }
        return try? NativeMermaidRenderer.image(source: source, theme: theme)
    }
}

@MainActor
private final class WeakMermaidEditor {
    weak var value: EditorTextView?
    init(_ value: EditorTextView) { self.value = value }
}

/// Small, process-wide native-image cache. Rendering stays off the main actor;
/// a completed render invalidates only blocks containing the same Mermaid body.
@MainActor
final class MermaidImageStore {
    struct Key: Hashable, Sendable {
        let source: String
        let theme: MermaidThemeKey
    }

    static let shared = MermaidImageStore()

    private let capacity = 64
    private var images: [Key: NSImage] = [:]
    private var failed: Set<Key> = []
    private var insertionOrder: [Key] = []
    private var tasks: [Key: Task<Void, Never>] = [:]
    private var waiters: [Key: [WeakMermaidEditor]] = [:]

    func image(source: String, style: MermaidRenderStyle,
               requesting editor: EditorTextView) -> NSImage? {
        let key = Key(source: source, theme: style.key)
        if let image = images[key] { return image }
        guard !failed.contains(key) else { return nil }

        var listeners = waiters[key, default: []]
        listeners.removeAll { $0.value == nil }
        if !listeners.contains(where: { $0.value === editor }) {
            listeners.append(WeakMermaidEditor(editor))
        }
        waiters[key] = listeners

        guard tasks[key] == nil else { return nil }
        tasks[key] = Task { @MainActor [weak self] in
            let image = await MermaidRenderWorker.shared.image(
                source: source, theme: style.theme)
            self?.finish(image: image, for: key)
        }
        return nil
    }

    /// Test/preflight hook that uses the same coalesced cache as editor styling.
    func prepare(source: String, style: MermaidRenderStyle) async -> NSImage? {
        let key = Key(source: source, theme: style.key)
        if let image = images[key] { return image }
        if failed.contains(key) { return nil }
        if let task = tasks[key] {
            await task.value
            return images[key]
        }

        tasks[key] = Task { @MainActor [weak self] in
            let image = await MermaidRenderWorker.shared.image(
                source: source, theme: style.theme)
            self?.finish(image: image, for: key)
        }
        await tasks[key]?.value
        return images[key]
    }

    private func finish(image: NSImage?, for key: Key) {
        tasks[key] = nil
        if let image {
            images[key] = image
            insertionOrder.append(key)
            while insertionOrder.count > capacity {
                let evicted = insertionOrder.removeFirst()
                images[evicted] = nil
                failed.remove(evicted)
            }
        } else {
            failed.insert(key)
        }

        let editors = waiters.removeValue(forKey: key)?
            .compactMap(\.value) ?? []
        for editor in editors {
            editor.mermaidImageDidRender(source: key.source)
        }
    }
}

extension EditorTextView {
    /// Replaces an inactive Mermaid fence with the cached native image. On a
    /// cache miss the ordinary code-block box remains visible until the
    /// background render completes.
    func styleMermaidBlock(_ result: NSMutableAttributedString,
                           span: SyntaxHighlighter.Span,
                           source: String) -> Bool {
        let style = MermaidRenderStyle(editorTheme: theme, dark: isDarkAppearance)
        guard let image = MermaidImageStore.shared.image(
            source: source, style: style, requesting: self),
              image.size.width > 0, image.size.height > 0 else { return false }

        let maxWidth = max(1, availableContentWidth)
        let scale = min(1, maxWidth / image.size.width)
        let width = image.size.width * scale
        let height = image.size.height * scale
        let x = max(0, (maxWidth - width) / 2)
        let overlay = FragmentOverlay(
            image: image,
            bounds: CGRect(x: x, y: 0, width: width, height: height)
        )

        // Every source character remains in storage. Near-zero hidden rows
        // collapse the code body while the opening-fence paragraph reserves
        // the diagram's height and carries its overlay.
        result.addAttribute(.font, value: hiddenFont, range: span.fullRange)
        result.addAttribute(.foregroundColor, value: NSColor.clear, range: span.fullRange)
        let collapsed = NSMutableParagraphStyle()
        collapsed.minimumLineHeight = hiddenFont.pointSize
        result.addAttribute(.paragraphStyle, value: collapsed, range: span.fullRange)

        let anchor = NSRange(location: span.fullRange.location, length: 1)
        applyOverlay(overlay, anchor: anchor, in: result)
        reserveLineHeight(ascent: height, descent: 0,
                          forOverlayAt: anchor.location, in: result)

        let ns = result.string as NSString
        let firstLine = NSIntersectionRange(
            ns.paragraphRange(for: NSRange(location: anchor.location, length: 0)),
            span.fullRange
        )
        if firstLine.length > 0,
           let base = result.attribute(.paragraphStyle, at: anchor.location,
                                       effectiveRange: nil) as? NSParagraphStyle {
            let spaced = base.mutableCopy() as! NSMutableParagraphStyle
            spaced.paragraphSpacingBefore = 8
            spaced.paragraphSpacing = 8
            result.addAttribute(.paragraphStyle, value: spaced, range: firstLine)
        }
        return true
    }

    /// A background render may finish during typing or IME composition. In
    /// those states the cache is left ready and the normal next styling pass
    /// picks it up; no asynchronous attribute write is allowed to race the edit.
    func mermaidImageDidRender(source: String) {
        guard markdownFeatures.contains(.mermaid),
              !isUpdating, !hasMarkedText(),
              (textStorage as? EditorTextStorage)?.pendingEdit == nil else { return }

        var dirty = IndexSet()
        for index in blocks.indices where blocks[index].content.contains(source) {
            let content = blocks[index].content
            let ns = content as NSString
            let matches = SyntaxHighlighter.parse(content, features: markdownFeatures).contains {
                guard case .codeBlock(let language) = $0.kind,
                      MermaidSyntax.matches(language: language),
                      $0.contentRange.upperBound <= ns.length else { return false }
                return ns.substring(with: $0.contentRange) == source
            }
            if matches { dirty.insert(index) }
        }
        guard !dirty.isEmpty else { return }
        recomposeDirty(dirty, cursorInRaw: currentCursorInRaw())
    }
}

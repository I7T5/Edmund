// RenderPng — DEBUG-only offscreen renderer for visual verification when
// `screencapture` has no Screen Recording grant (CLAUDE.md's sanctioned
// fallback: "render the editor offscreen to a PNG").
//
//   edmd -debug.renderPng <outDir> <file.md>
//
// Writes three PNGs into <outDir> (existing files are overwritten):
//   editor-no-cascade.png — Edit view, theme as persisted
//   editor-cascade.png    — Edit view, cascade forced via -debug.cascadeFonts
//   read-cascade.png      — ReadModeWebView render of the same cascade theme
//
// The cascade override is a JSON dictionary of script → family:
//   -debug.cascadeFonts '{"han":"Songti SC","emoji":"Apple Color Emoji"}'
//
// Uses the app's own Document window (not a fresh editor) so the pixels match
// what the app draws. Process exits when the captures finish; the window is
// never ordered in.

#if DEBUG
import AppKit
import SwiftUI
import EdmundCore

enum RenderPng {

    /// Debug trace goes to a file (stdout from a backgrounded GUI app is not
    /// reliably captured by the invoking shell).
    private static func trace(_ message: String) {
        NSLog("renderPng: \(message)")
        let line = "renderPng: \(message)\n"
        let path = "/tmp/edmund-renderpng.log"
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// Whether `-debug.renderPng` was passed at all (with or without its
    /// operands). main.swift consults this to route the file-open.
    static var isRequested: Bool {
        CommandLine.arguments.contains("-debug.renderPng")
    }

    /// Parsed from the argument domain. Returns nil unless `-debug.renderPng`
    /// was passed (with its <outDir> <file.md> operands).
    ///
    /// The operands need not sit immediately after the flag: other `-debug.*`
    /// flags may appear between `-debug.renderPng` and the file. A bare
    /// `hasPrefix("-")` skip is not enough — flags that take a value
    /// (e.g. `-debug.cascadeFonts '<json>'`) consume their next argument,
    /// which must be skipped too or the JSON gets misread as the file (the
    /// run then dies with "document never appeared"). The old fixed-offset
    /// parse had the same failure with any interleaved flag.
    static var request: (outDir: String, file: String)? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-debug.renderPng") else { return nil }
        var operands: [String] = []
        var j = i + 1
        while j < args.count, operands.count < 2 {
            let arg = args[j]
            if valueTakingDebugFlags.contains(arg) {
                j += 2  // skip the flag and its value
                continue
            }
            if arg.hasPrefix("-") {
                j += 1  // bare flag (e.g. -debug.renderPng restores)
                continue
            }
            operands.append(arg)
            j += 1
        }
        guard operands.count == 2 else { return nil }
        return (operands[0], operands[1])
    }

    /// Debug flags that consume the next argument as their value. `-debug.*`
    /// flags read via UserDefaults (reproScript, disableUpdater) take one too,
    /// but only the ones parsed from argv need listing here — the others are
    /// never interleaved with a render run.
    private static let valueTakingDebugFlags: Set<String> = [
        "-debug.cascadeFonts",
        "-debug.reproScript",
        "-debug.disableUpdater",
    ]

    /// The optional cascade override: -debug.cascadeFonts '<json>'.
    static var cascadeOverride: [FontCascadeScript: String]? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-debug.cascadeFonts"), i + 1 < args.count,
              let data = args[i + 1].data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        var cascade: [FontCascadeScript: String] = [:]
        for (key, family) in raw {
            if let script = FontCascadeScript(rawValue: key) { cascade[script] = family }
        }
        return cascade
    }

    /// Runs after the document window is set up; exits the process when done.
    @MainActor
    static func runIfRequested() {
        guard isRequested else { return }
        // Any launch carrying the flag is a render run — including the
        // restoration relaunch, where AppKit re-execs us with clean argv and
        // the flag lives on only in the argument domain. Whatever documents
        // restoration brings back are re-rendered along with the fixture.
        guard let request else {
            trace("missing <outDir> <file.md> operands")
            NSApp.terminate(nil)
            return
        }
        trace("requested for \(request.file)")
        // Poll for the document instead of a fixed delay: NSDocumentController
        // opens the launch-argument file asynchronously.
        Task { @MainActor in
            var document: Document?
            for _ in 0..<40 where document == nil {
                document = NSDocumentController.shared.documents
                    .compactMap { $0 as? Document }
                    .first { $0.fileURL?.path == request.file }
                if document == nil {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            guard let document else {
                trace("document never appeared for \(request.file)")
                NSApp.terminate(nil)
                return
            }
            // capture() drives termination itself once its last snapshot is
            // written (the read-view shot happens in onLoadFinished, after
            // capture returns).
            await capture(request, document: document)
        }
    }

    /// Fallback deadline (seconds from the read render's start) after which
    /// the read snapshot is taken and the app exits even if `onLoadFinished`
    /// never fired.
    private static let readCaptureDeadline: TimeInterval = 8

    @MainActor
    private static func capture(_ request: (outDir: String, file: String),
                                document: Document) async {
        guard let editor = document.editor else {
            trace("editor not ready")
            return
        }
        // Keep the window ordered in and the app active: with the window
        // ordered out the process is treated as fully occluded, AppKit throttles
        // its runloop sources (timers/queues stop firing), and the WebKit
        // capture below never proceeds past onLoadFinished. Snapshots read the
        // backing store, so onscreen-ness doesn't matter — and with no Screen
        // Recording grant nothing is capturable anyway.
        editor.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        trace("document ready, capturing editor")

        // Sampling fonts via -attributes(at:effectiveRange:) can itself
        // trip a re-fix (documented Cocoa gotcha), but the sample is for
        // diagnostics only — the snapshot is the assertion.
        trace("漢 font BEFORE cascade: \(sampleHanFont(in: editor)?.fontName ?? "nil (no 漢 in fixture)")")

        write(snapshot(editor), to: "\(request.outDir)/editor-no-cascade.png")

        // Settings panes: SwiftUI views rendered offscreen via NSHostingView.
        // Appearance is the reference layout; Fonts must match it. The Fonts
        // pane gets a couple of cascade entries so the preview fields exercise
        // the per-script font path (nil = system fallback otherwise).
        let fonts = FontSettings()
        fonts.setCascadeFont(.han, family: "Kaiti SC")
        fonts.setCascadeFont(.emoji, family: "Apple Color Emoji")
        let appearanceView = NSHostingView(rootView: AppearanceSettingsView(fonts: fonts))
        let fontsView = NSHostingView(rootView: FontCascadeSettingsView(fonts: fonts))
        // 600pt: the Settings window's fixed pane width (SettingsPaneWidthTests).
        for (view, name) in [(appearanceView, "settings-appearance"),
                             (fontsView, "settings-fonts")] {
            view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
            view.layoutSubtreeIfNeeded()
            view.frame.size = view.fittingSize
            write(snapshot(view), to: "\(request.outDir)/\(name).png")
            trace("wrote \(name).png")
        }

        if let cascade = cascadeOverride {
            var theme = editor.theme
            theme.fontCascade = cascade
            editor.applyTheme(theme, persist: false)
            let resolverSet = (editor.textStorage as? EditorTextStorage)?.cascadeResolver != nil
            trace("cascade applied, resolver=\(resolverSet), theme cascade=\(editor.theme.fontCascade)")
            // Sampling fonts via -attributes(at:effectiveRange:) can itself
            // trip a re-fix (documented Cocoa gotcha), but the sample is for
            // diagnostics only — the snapshot is the assertion.
            trace("漢 font after cascade: \(sampleHanFont(in: editor)?.fontName ?? "nil (no 漢 in fixture)")")
            write(snapshot(editor), to: "\(request.outDir)/editor-cascade.png")

            // The exact HTML the read view will load — dumped so a failing
            // render can be diffed without a web inspector.
            let html = DocumentHTML.debugFull(markdown: editor.rawSource, theme: theme,
                                              callouts: Callout.defaultStyles,
                                              baseURL: document.fileURL?.deletingLastPathComponent())
            try? html.write(to: URL(fileURLWithPath: "\(request.outDir)/read-cascade.html"),
                            atomically: true, encoding: .utf8)

            // Read view: the real ReadModeWebView pipeline, captured offscreen.
            trace("webkit render next")
            let read = ReadModeWebView()
            read.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            editor.window?.contentView?.addSubview(read)
            trace("read: render() called")
            var didSnapshot = false
            let takeSnapshot = { [weak read] in
                guard !didSnapshot, let read else { return }
                didSnapshot = true
                trace("read: snapshotting")
                write(snapshot(read), to: "\(request.outDir)/read-cascade.png")
                trace("read capture done; terminating")
                NSApp.terminate(nil)
                Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in exit(0) }
            }
            read.onLoadFinished = {
                trace("read: onLoadFinished")
                // Give WebKit a beat to paint the freshly loaded document.
                Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                    takeSnapshot()
                }
            }
            read.render(markdown: editor.rawSource, theme: theme,
                        callouts: Callout.defaultStyles,
                        baseURL: document.fileURL?.deletingLastPathComponent())
            trace("read: render() returned")
            // Backstop: onLoadFinished-driven capture is the norm, but if the
            // runloop stalls before it fires, take whatever is on screen at
            // the deadline rather than hanging the render run forever.
            try? await Task.sleep(nanoseconds: UInt64(readCaptureDeadline * 1_000_000_000))
            trace("read: deadline reached (didSnapshot=\(didSnapshot))")
            takeSnapshot()
            return
        }
        trace("no cascade override; terminating after editor shots")
        NSApp.terminate(nil)
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in exit(0) }
    }

    /// The font drawn for the first 漢 in the editor's text storage, or nil
    /// when the fixture contains no 漢. `range(of:).location` is NSNotFound
    /// (Int.max) in that case and must never reach `attributes(at:)`, which
    /// raises NSRangeException out of bounds.
    @MainActor
    private static func sampleHanFont(in editor: EditorTextView) -> NSFont? {
        guard let ts = editor.textStorage else { return nil }
        let loc = (ts.string as NSString).range(of: "漢").location
        guard loc != NSNotFound else { return nil }
        return ts.attributes(at: loc, effectiveRange: nil)[.font] as? NSFont
    }

    @MainActor
    private static func snapshot(_ view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        // Offscreen views are never vended a viewport by the layout manager —
        // without this, fragments keep estimated heights and glyphs never draw.
        (view as? EditorTextView)?.textLayoutManager?
            .textViewportLayoutController.layoutViewport()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func write(_ data: Data?, to path: String) {
        guard let data else {
            trace("snapshot failed for \(path)")
            return
        }
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path))
            trace("wrote \(path)")
        } catch {
            trace("\(error)")
        }
    }
}
#endif

import Testing
import AppKit
import Foundation
@testable import EdmundCore

// LOCAL DEV TOOL (gitignored): renders the Edit-mode editor offscreen to a PNG
// so callout icon / checkbox alignment can be measured. Run:
//   swift test --filter RenderEdit
@Suite("RenderEdit") @MainActor
struct RenderEdit {
    @Test func render() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let md = try String(contentsOf: root.appendingPathComponent("tmp/sample.md"), encoding: .utf8)

        for (name, dark) in [("light", false), ("dark", true)] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            appearance.performAsCurrentDrawingAppearance {
                let editor = makeEditor()
                editor.appearance = appearance
                let width: CGFloat = 460
                editor.frame = NSRect(x: 0, y: 0, width: width, height: 1500)
                editor.loadContent(md)
                ensureFullLayout(editor)
                drainAllStyling(editor)
                ensureFullLayout(editor)

                // Fit height to content.
                let used = editor.textLayoutManager?.usageBoundsForTextContainer.height ?? 1500
                let h = ceil(used) + 24
                editor.frame = NSRect(x: 0, y: 0, width: width, height: h)
                ensureFullLayout(editor)

                let scale: CGFloat = 2
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(width * scale), pixelsHigh: Int(h * scale),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = NSSize(width: width, height: h)
                NSGraphicsContext.saveGraphicsState()
                let ctx = NSGraphicsContext(bitmapImageRep: rep)!
                NSGraphicsContext.current = ctx
                // Paint the editor's background, then draw the view tree.
                (editor.backgroundColor).setFill()
                NSRect(x: 0, y: 0, width: width, height: h).fill()
                editor.displayIgnoringOpacity(editor.bounds, in: ctx)
                NSGraphicsContext.restoreGraphicsState()

                let png = rep.representation(using: .png, properties: [:])!
                try! png.write(to: root.appendingPathComponent("tmp/edit-\(name).png"))
            }
        }
    }
}

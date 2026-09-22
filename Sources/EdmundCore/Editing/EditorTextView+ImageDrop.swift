import AppKit
import UniformTypeIdentifiers

// MARK: - Dropping image files
//
// The attach flow (EditorTextView+ImageAttachments) owns image drops end to
// end: `draggingEntered`/`draggingUpdated` advertise .copy for image content,
// and `performDragOperation` copies the file into the document's assets
// folder (Option-drop links in place) — see that file for the policies.
//
// What remains here is only the *typing* plumbing. `.fileURL` must outrank
// `.string`, or a Finder drag — which carries both a file URL and a
// plain-string representation of the path — would paste a bare path instead
// of reaching the attach flow. And a NON-image file drop must fall through
// `.fileURL` (our `readSelection` declines it) to the next type, so AppKit
// pastes the path as text, as it always did.

extension EditorTextView {

    /// `.fileURL` must come **first**: `readSelection(from:)` takes the
    /// first supported type it finds. This list also drives `paste:`, so ⌘V
    /// of an image file copied in Finder reaches the attach flow.
    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + super.readablePasteboardTypes
    }

    public override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + super.acceptableDragTypes
    }

    /// Never consumes `.fileURL` content. Image drops never reach here —
    /// `performDragOperation` (ImageAttachments) intercepts them first — so
    /// the only file drops that arrive are non-images, which must fall
    /// through to `.string` rather than be swallowed.
    public override func readSelection(from pboard: NSPasteboard,
                                       type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .fileURL else { return super.readSelection(from: pboard, type: type) }
        return false
    }
}

import AppKit

/// A text storage subclass that preserves `.attachment` attributes on
/// any character, not just the object replacement character (\u{FFFC}).
///
/// Standard NSTextStorage strips attachments from non-FFFC characters
/// during `fixAttributes`. This subclass skips attribute fixing since
/// the editor explicitly manages all attributes for every character.
public class EditorTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()

    override public var string: String { backing.string }

    override public func attributes(
        at location: Int, effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override public func replaceCharacters(in range: NSRange, with str: String) {
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range,
               changeInLength: (str as NSString).length - range.length)
    }

    override public func replaceCharacters(in range: NSRange, with attrString: NSAttributedString) {
        backing.replaceCharacters(in: range, with: attrString)
        edited([.editedCharacters, .editedAttributes], range: range,
               changeInLength: attrString.length - range.length)
    }

    override public func setAttributes(
        _ attrs: [NSAttributedString.Key: Any]?, range: NSRange
    ) {
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
    }

    override public func fixAttributes(in range: NSRange) {
        // Skip default attribute fixing. The editor sets all attributes
        // explicitly for every character, so no automatic fixing is needed.
        // This preserves .attachment attributes on non-FFFC characters
        // (used for checkbox circle icons).
    }
}

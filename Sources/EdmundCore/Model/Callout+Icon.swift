import AppKit

// Callout.swift stays Foundation-only — its fields are deliberately plain and
// serializable — so the one AppKit-shaped accessor lives here.

extension Callout {
    /// A callout type's header icon, tinted to `color`, or nil for an unknown
    /// type. Exists so the app module can draw the same glyph the editor draws
    /// without `LucideIcons` (which is internal) leaking out of EdmundCore.
    ///
    /// The caller picks the tint: the editor uses the callout's own accent, the
    /// format popover draws it monochrome so it sits with the other rows.
    public static func icon(for type: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
        guard let style = style(for: type) else { return nil }
        return LucideIcons.image(style.iconName, color: color, pointSize: pointSize)
    }
}

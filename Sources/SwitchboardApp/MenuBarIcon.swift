import AppKit

/// Streamline's Ultimate Color "like" icon. Attribution: THIRD_PARTY_NOTICES.md.
enum MenuBarIcon {
    static func thumbsUp(size: CGFloat = 18) -> NSImage {
        // Keep the original colors and vector geometry at every display scale.
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path fill="#ffdda1" stroke="#191919" stroke-linecap="round" stroke-linejoin="round" d="M19.5 16.065a1.5 1.5 0 1 1 0 3h-1a1.5 1.5 0 1 1 0 3H12c-4 0-3-2-11-2v-9h3a7.95 7.95 0 0 0 7.5-8c0-1.581 3-1.781 3 1.219a31.6 31.6 0 0 1-1 5.78h8a1.5 1.5 0 1 1 0 3h-1a1.5 1.5 0 1 1 0 3z"/></svg>
        """
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage(systemSymbolName: "hand.thumbsup.fill", accessibilityDescription: nil)!
        image.size = NSSize(width: size, height: size)
        image.isTemplate = false
        image.accessibilityDescription = "Codex Switchboard"
        return image
    }
}

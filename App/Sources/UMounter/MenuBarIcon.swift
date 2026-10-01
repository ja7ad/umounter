import AppKit
import UMounterCore

/// UMounter's menu bar icon. The glyph family is the user's choice
/// (Settings → General → Icon style); the state is always readable at a glance,
/// with counts and checkmarks punched out of a small badge (not Jettison's glyph + text).
///
/// | State           | Eject          | Eject Circle         | Drive                          |
/// |-----------------|----------------|----------------------|--------------------------------|
/// | no disks        | outlined       | outlined             | outlined                       |
/// | N disks mounted | filled + "N"   | filled + "N"         | filled + "N"                   |
/// | working         | filled + "…"   | filled + "…"         | filled + "…"                   |
/// | safe to unplug  | outlined + "✓" | `checkmark.circle`   | `externaldrive.badge.checkmark`|
///
/// Images are template images so the menu bar tints them for light/dark and
/// highlight. Rendering is cached per state and style; it only runs when either changes.
@MainActor
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for state: StatusIconState, style: MenuBarIconStyle, showCount: Bool) -> NSImage {
        let key = "\(state)-\(style)-\(showCount)"
        if let cached = cache[key] { return cached }
        let (outline, filled) = glyphs(style)
        let image: NSImage = switch state {
        case .empty:
            symbol(outline)
        case .safeToUnplug:
            switch style {
            case .eject: badged(outline, text: "✓")
            case .ejectCircle: symbol("checkmark.circle")
            case .drive: symbol("externaldrive.badge.checkmark")
            }
        case .mounted(let count):
            showCount && count > 0 ? badged(filled, text: count > 9 ? "9+" : "\(count)") : symbol(filled)
        case .working:
            badged(filled, text: "…")
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    private static func glyphs(_ style: MenuBarIconStyle) -> (outline: String, filled: String) {
        switch style {
        case .eject: ("eject", "eject.fill")
        case .ejectCircle: ("eject.circle", "eject.circle.fill")
        case .drive: ("externaldrive", "externaldrive.fill")
        }
    }

    private static let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)

    private static func symbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// Draws `name` with a pill badge at the bottom-right. The badge is separated from
    /// the glyph by a transparent gap and its text is knocked out, so it stays legible
    /// as a single-colour template image.
    private static func badged(_ name: String, text: String) -> NSImage {
        let base = symbol(name)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (text as NSString).size(withAttributes: attributes)

        let badgeHeight: CGFloat = 10.5
        let badgeWidth = max(badgeHeight, ceil(textSize.width) + 4.5)
        let size = NSSize(width: ceil(base.size.width + badgeWidth * 0.45), height: max(base.size.height, 16))

        return NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            base.draw(in: NSRect(x: 0, y: (size.height - base.size.height) / 2, width: base.size.width, height: base.size.height))

            let badge = NSRect(x: size.width - badgeWidth, y: 0, width: badgeWidth, height: badgeHeight)

            context.setBlendMode(.destinationOut) // gap between glyph and badge
            NSBezierPath(roundedRect: badge.insetBy(dx: -1.5, dy: -1.5), xRadius: badgeHeight / 2 + 1.5, yRadius: badgeHeight / 2 + 1.5).fill()

            context.setBlendMode(.normal)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: badge, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()

            context.setBlendMode(.destinationOut) // knock the text out of the badge
            let origin = NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2 + 0.25)
            (text as NSString).draw(at: origin, withAttributes: attributes)
            return true
        }
    }
}

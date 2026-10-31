import AppKit
import SwiftUI

/// The icon in the menu bar. A warning (for example "callers will hear themselves") puts an
/// orange dot on it, so it can be seen without opening the menu.
enum MenuBarIcon {
    static func image(badge: Bool) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let symbol = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Duette")?
            .withSymbolConfiguration(configuration) ?? NSImage(size: NSSize(width: 18, height: 18))
        guard badge else {
            symbol.isTemplate = true
            return symbol
        }
        let size = NSSize(width: max(symbol.size.width, 18) + 3, height: max(symbol.size.height, 18))
        let image = NSImage(size: size, flipped: false) { rect in
            // The symbol in the colour of the menu bar text, then the dot in the top right corner.
            let glyph = NSRect(x: 0, y: 0, width: symbol.size.width, height: symbol.size.height)
            let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
                symbol.draw(in: bounds)
                NSColor.labelColor.set()
                bounds.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: glyph)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 8, y: rect.maxY - 8, width: 8, height: 8)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Duette, with a warning"
        return image
    }
}

/// What sits in the menu bar.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(nsImage: MenuBarIcon.image(badge: model.hasWarning))
            .accessibilityLabel(model.menuBarDescription)
    }
}

import AppKit

@MainActor
enum AgentMeterMascotIcon {
    private static var claudeCreatureCache: NSImage?
    private static var menuBarGlyphCache: NSImage?
    private static var tintedMenuBarGlyphCache: [String: NSImage] = [:]

    private static let resourceBundle: Bundle? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return Bundle.module
        }
        if let bundleURL = Bundle.main.url(forResource: "AgentMeter_AgentMeter", withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL)
        {
            return bundle
        }
        return Bundle.main
    }()

    static func claudeCreature() -> NSImage? {
        if let cached = self.claudeCreatureCache {
            return cached
        }
        guard let bundle = self.resourceBundle,
              let url = bundle.url(forResource: "AgentMeterMascot-claude-creature", withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        self.claudeCreatureCache = image
        return image
    }

    static func menuBarGlyph() -> NSImage? {
        if let cached = self.menuBarGlyphCache {
            return cached
        }
        let loadedImage: NSImage? = {
            guard let bundle = self.resourceBundle,
                  let url = bundle.url(forResource: "AgentMeterMenuBarIcon", withExtension: "svg"),
                  let image = NSImage(contentsOf: url)
            else {
                return NSImage(
                    systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                    accessibilityDescription: "AgentMeter")
            }
            return image
        }()
        guard let image = loadedImage else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        self.menuBarGlyphCache = image
        return image
    }

    static func menuBarGlyph(tint: NSColor) -> NSImage? {
        let key = tint.usingColorSpace(.deviceRGB)?.description ?? tint.description
        if let cached = self.tintedMenuBarGlyphCache[key] {
            return cached
        }
        guard let base = self.menuBarGlyph()?.copy() as? NSImage else { return nil }
        base.isTemplate = false

        let image = NSImage(size: base.size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: base.size)
        base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        tint.setFill()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        self.tintedMenuBarGlyphCache[key] = image
        return image
    }

    static func resetCacheForTesting() {
        self.claudeCreatureCache = nil
        self.menuBarGlyphCache = nil
        self.tintedMenuBarGlyphCache.removeAll()
    }
}

import AppKit
import CodexBarCore

@MainActor
enum AgentMeterMenuBarBadgeImage {
    private struct CacheKey: Hashable {
        let provider: UsageProvider
        let text: String
        let warningFlash: Bool
    }

    private static var cache: [CacheKey: NSImage] = [:]
    private static let height: CGFloat = 18
    private static let iconSize: CGFloat = 14
    private static let horizontalPadding: CGFloat = 5
    private static let gap: CGFloat = 4
    private static let minStatusItemLength: CGFloat = 38
    private static let maxStatusItemLength: CGFloat = 88

    static func image(
        provider: UsageProvider,
        text: String,
        baseImage: NSImage?,
        button _: NSStatusBarButton,
        warningFlash: Bool)
        -> NSImage
    {
        let key = CacheKey(
            provider: provider,
            text: text,
            warningFlash: warningFlash)
        if let cached = self.cache[key] {
            return cached
        }

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let textColor = NSColor.white.withAlphaComponent(0.94)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let textSize = (text as NSString).size(withAttributes: textAttributes)
        let width = min(
            self.maxStatusItemLength,
            max(
                self.minStatusItemLength,
                ceil(self.horizontalPadding * 2 + self.iconSize + self.gap + textSize.width)))
        let image = NSImage(size: NSSize(width: width, height: self.height))
        image.lockFocus()

        NSColor.black.withAlphaComponent(0.28).setFill()
        NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: image.size).insetBy(dx: 0.5, dy: 1),
            xRadius: 4,
            yRadius: 4).fill()

        if warningFlash {
            NSColor.systemRed.withAlphaComponent(0.24).setFill()
            NSBezierPath(
                roundedRect: NSRect(origin: .zero, size: image.size).insetBy(dx: 0.5, dy: 1),
                xRadius: 4,
                yRadius: 4).fill()
        }

        let iconRect = NSRect(
            x: self.horizontalPadding,
            y: (self.height - self.iconSize) / 2,
            width: self.iconSize,
            height: self.iconSize)
        if let baseImage {
            self.draw(baseImage, in: iconRect, tint: textColor)
        }

        let textRect = NSRect(
            x: self.horizontalPadding + self.iconSize + self.gap,
            y: floor((self.height - textSize.height) / 2),
            width: width - self.horizontalPadding * 2 - self.iconSize - self.gap,
            height: textSize.height)
        (text as NSString).draw(in: textRect, withAttributes: textAttributes)

        image.unlockFocus()
        image.isTemplate = false
        self.cache[key] = image
        return image
    }

    static func statusItemLength(for image: NSImage) -> CGFloat {
        min(self.maxStatusItemLength + 6, max(self.minStatusItemLength + 6, ceil(image.size.width + 6)))
    }

    static func resetCacheForTesting() {
        self.cache.removeAll()
    }

    private static func draw(_ image: NSImage, in rect: NSRect, tint: NSColor) {
        guard image.isTemplate else {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }

        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        tint.setFill()
        rect.fill(using: .sourceAtop)
    }
}

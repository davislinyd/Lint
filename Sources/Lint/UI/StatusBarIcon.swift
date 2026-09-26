import AppKit
import LintCore

/// Lint's menu bar icon: the pen nib and check of the app icon, with a dot for the local model's state.
enum StatusBarIcon {
    static let size = NSSize(width: 18, height: 18)

    /// `activity` is nil when the requests do not go to Lint's local model: the glyph alone, as a
    /// template image the menu bar tints. With a state the image is drawn in the menu bar's text color
    /// (resolved when drawn, so it follows a light or dark menu bar) because the dot has its own color.
    static func image(activity: LocalModelActivity?) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(activity, in: context)
            return true
        }
        image.isTemplate = activity == nil
        image.accessibilityDescription = "Lint"
        return image
    }

    private static func draw(_ activity: LocalModelActivity?, in context: CGContext) {
        // Everything is drawn in one layer, so the knock-outs clear only the glyph, never the menu bar.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }

        let glyphColor = activity == .notLoaded
            ? NSColor.controlTextColor.withAlphaComponent(0.45) : NSColor.controlTextColor
        context.saveGState()
        // With a dot the glyph moves left, so the dot does not cut into the check.
        if activity != nil { context.translateBy(x: -1.5, y: 0) }
        context.setFillColor(glyphColor.cgColor)
        context.addPath(nib)
        context.fillPath()
        context.addPath(check)
        context.fillPath()

        context.setBlendMode(.clear)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        // The original gaps are well under a pixel at this size: each is widened to stay visible.
        context.setLineWidth(0.8)
        context.addPath(slit)
        context.strokePath()
        context.addEllipse(in: CGRect(x: hole.x - 1, y: hole.y - 1, width: 2, height: 2))
        context.fillPath()
        context.setLineWidth(0.75)
        context.addPath(armGaps)
        context.strokePath()
        context.restoreGState()

        guard let dot = activity.flatMap(dotStyle) else { return }
        let center = CGPoint(x: 15, y: 15)
        context.setBlendMode(.clear)
        context.addEllipse(in: CGRect(x: center.x - 3.6, y: center.y - 3.6, width: 7.2, height: 7.2))
        context.fillPath()
        context.setBlendMode(.normal)
        switch dot {
        case .filled(let color):
            context.setFillColor(color.cgColor)
            context.addEllipse(in: CGRect(x: center.x - 2.7, y: center.y - 2.7, width: 5.4, height: 5.4))
            context.fillPath()
        case .hollow(let color):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1.1)
            context.addEllipse(in: CGRect(x: center.x - 2.15, y: center.y - 2.15, width: 4.3, height: 4.3))
            context.strokePath()
        }
    }

    private enum Dot {
        case filled(NSColor)
        case hollow(NSColor)
    }

    private static func dotStyle(_ activity: LocalModelActivity) -> Dot? {
        switch activity {
        case .notLoaded: nil
        case .loading, .restarting: .filled(.systemYellow)
        case .running: .filled(.systemGreen)
        case .idle: .hollow(.systemGray)
        case .failed: .filled(.systemRed)
        }
    }

    // MARK: - Glyph

    // Traced from Resources/AppIcon-master.png: points are in its 1024-pixel space (y down), the glyph
    // spans y 205...824 and is centered on x 511.5, and it is scaled to 16 pt with 1 pt above.
    private static let scale: CGFloat = 16.0 / 619

    private static func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: 8 + (x - 511.5) * scale, y: 1 + (y - 205) * scale)
    }

    /// The same point on the other side of the nib.
    private static func mirrored(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        point(1023 - x, y)
    }

    /// The nib's outline: the head, the two curved shoulders and the point; the slit, the hole and the
    /// gaps that set the shoulders apart are cut out of it.
    private static var nib: CGPath {
        let path = CGMutablePath()
        path.move(to: point(511.5, 205))
        path.addLine(to: point(653, 457))
        path.addCurve(to: point(600, 628), control1: point(655, 500), control2: point(602, 560))
        path.addLine(to: point(588, 633))
        path.addLine(to: point(566, 636))
        path.addLine(to: point(511.5, 693))
        path.addLine(to: mirrored(566, 636))
        path.addLine(to: mirrored(588, 633))
        path.addLine(to: mirrored(600, 628))
        path.addCurve(to: mirrored(653, 457), control1: mirrored(602, 560), control2: mirrored(655, 500))
        path.closeSubpath()
        return path
    }

    private static let hole = point(511.5, 418)

    private static var slit: CGPath {
        let path = CGMutablePath()
        path.move(to: point(511.5, 190))
        path.addLine(to: hole)
        return path
    }

    private static var armGaps: CGPath {
        let left: [(CGFloat, CGFloat)] = [
            (360, 466), (387, 480), (408, 500), (422, 520), (432, 540), (439, 560),
            (443, 580), (446, 600), (448, 622), (449, 648),
        ]
        let path = CGMutablePath()
        path.addLines(between: left.map { point($0.0, $0.1) })
        path.addLines(between: left.map { mirrored($0.0, $0.1) })
        return path
    }

    private static var check: CGPath {
        let path = CGMutablePath()
        path.addLines(between: [
            point(433, 688), point(507, 745), point(679, 600), point(693, 599),
            point(507, 824), point(411, 710),
        ])
        path.closeSubpath()
        return path
    }
}

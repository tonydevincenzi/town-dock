import AppKit
import SwiftUI

/// Phosphor Icons' bold `stack` glyph, adapted to native drawing.
/// Source: https://github.com/phosphor-icons/core (MIT)
struct PhosphorStackIcon: View {
    var color: Color = .primary

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 256
            let offset = CGPoint(
                x: (size.width - 256 * scale) / 2,
                y: (size.height - 256 * scale) / 2
            )

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: offset.x + x * scale, y: offset.y + y * scale)
            }

            let layers = [
                [point(32, 80), point(128, 24), point(224, 80), point(128, 136), point(32, 80)],
                [point(32, 128), point(128, 184), point(224, 128)],
                [point(32, 176), point(128, 232), point(224, 176)],
            ]
            for layer in layers {
                var path = Path()
                path.move(to: layer[0])
                for point in layer.dropFirst() { path.addLine(to: point) }
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 24 * scale, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

enum TownDockIcon {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 19), flipped: false) { rect in
            NSColor.black.setStroke()
            let scale = min(rect.width, rect.height) / 256
            let transform = NSAffineTransform()
            transform.translateX(by: (rect.width - 256 * scale) / 2, yBy: (rect.height - 256 * scale) / 2)
            transform.scale(by: scale)

            for layer in [
                [NSPoint(x: 32, y: 176), NSPoint(x: 128, y: 232), NSPoint(x: 224, y: 176), NSPoint(x: 128, y: 120), NSPoint(x: 32, y: 176)],
                [NSPoint(x: 32, y: 128), NSPoint(x: 128, y: 72), NSPoint(x: 224, y: 128)],
                [NSPoint(x: 32, y: 80), NSPoint(x: 128, y: 24), NSPoint(x: 224, y: 80)],
            ] {
                let path = NSBezierPath()
                path.move(to: layer[0])
                for point in layer.dropFirst() { path.line(to: point) }
                path.transform(using: transform as AffineTransform)
                path.lineWidth = 24 * scale
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Town Dock"
        return image
    }
}

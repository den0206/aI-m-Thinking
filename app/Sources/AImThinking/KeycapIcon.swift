import AppKit

/// Menu bar icon: a keycap seen from the front-left and slightly above, so its
/// top, front and right faces show, with `label` printed on the top face.
/// Drawn as a template image (macOS tints it for light/dark menu bars); the
/// side faces use partial alpha as shading.
enum KeycapIcon {
    /// Travel frames from released (0) to bottomed out (last), in half-point
    /// steps so each frame lands on a Retina pixel.
    static let frames = (0...4).map { make(label: label, sink: CGFloat($0) * 0.5) }

    #if DEBUG
    private static let label = "debug"  // tells debug and release apart in the menu bar
    #else
    private static let label = "thinking"
    #endif

    /// `sink` lowers the top face toward the fixed base, shortening the sides,
    /// as a key does when struck.
    static func make(label: String, sink: CGFloat) -> NSImage {
        let font = NSFont.systemFont(ofSize: 7, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (label as NSString).size(withAttributes: attributes)

        let height: CGFloat = 18
        let line: CGFloat = 1
        let skew: CGFloat = 3      // back edge shifted right: the view from the left
        let taper: CGFloat = 2.2   // base is wider than the top face
        let faceWidth = ceil(textSize.width) + 7
        let width = faceWidth + skew + taper * 2 + line * 2
        let size = NSSize(width: width, height: height)

        // Top face (parallelogram), flipped coordinates: y grows downward.
        let top = 1.2 + sink
        let faceDepth: CGFloat = 9.5
        let left = taper + line
        let right = left + faceWidth
        let backLeft = NSPoint(x: left + skew, y: top)
        let backRight = NSPoint(x: right + skew, y: top)
        let frontRight = NSPoint(x: right, y: top + faceDepth)
        let frontLeft = NSPoint(x: left, y: top + faceDepth)

        // Base stays put; only the cap above it moves.
        let baseY = height - line / 2
        let baseFrontLeft = NSPoint(x: left - taper, y: baseY)
        let baseFrontRight = NSPoint(x: right + taper, y: baseY)
        let baseBackRight = NSPoint(x: right + skew + taper, y: baseY - faceDepth + 1)

        func polygon(_ points: [NSPoint]) -> NSBezierPath {
            let path = NSBezierPath()
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = line
            return path
        }

        let image = NSImage(size: size, flipped: true) { _ in
            let front = polygon([frontLeft, frontRight, baseFrontRight, baseFrontLeft])
            let side = polygon([frontRight, backRight, baseBackRight, baseFrontRight])
            let face = polygon([backLeft, backRight, frontRight, frontLeft])

            // Shading: the right side is in shadow, the front a little less.
            NSColor.black.withAlphaComponent(0.55).setFill()
            side.fill()
            NSColor.black.withAlphaComponent(0.25).setFill()
            front.fill()

            NSColor.black.setStroke()
            [front, side, face].forEach { $0.stroke() }

            // Print the label on the top face, sheared to follow its slant.
            NSGraphicsContext.saveGraphicsState()
            let shear = NSAffineTransform()
            shear.transformStruct = NSAffineTransformStruct(
                m11: 1, m12: 0,
                m21: -skew / faceDepth, m22: 1,
                tX: skew * (top + faceDepth) / faceDepth, tY: 0
            )
            shear.concat()
            let origin = NSPoint(
                x: left + (faceWidth - textSize.width) / 2,
                y: top + (faceDepth - textSize.height) / 2
            )
            (label as NSString).draw(at: origin, withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }
}

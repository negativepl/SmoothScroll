import AppKit

let size = 1024.0
let cx = size / 2

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    // === Background — deep blue gradient rounded rect ===
    let bgRect = rect.insetBy(dx: 40, dy: 40)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 190, yRadius: 190)

    let gradient = NSGradient(colors: [
        NSColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 1.0),
        NSColor(red: 0.15, green: 0.30, blue: 0.82, alpha: 1.0),
    ])!
    gradient.draw(in: bgPath, angle: -60)

    // Subtle border
    NSColor(white: 1.0, alpha: 0.12).setStroke()
    bgPath.lineWidth = 2.5
    bgPath.stroke()

    // === Smooth scroll flow curves (behind mouse) ===
    // Flowing S-curves emanating from center, suggesting smooth motion
    for i in 0..<5 {
        let offset = Double(i) * 38.0
        let alpha = 0.12 - Double(i) * 0.02
        let lineWidth = 3.5 - Double(i) * 0.4

        let curve = NSBezierPath()
        let startY = 180.0 - offset * 0.5
        let endY = 844.0 + offset * 0.5

        // Left curves
        curve.move(to: NSPoint(x: cx - 180 - offset, y: startY))
        curve.curve(
            to: NSPoint(x: cx - 180 - offset, y: endY),
            controlPoint1: NSPoint(x: cx - 250 - offset * 1.5, y: size * 0.38),
            controlPoint2: NSPoint(x: cx - 110 - offset * 0.5, y: size * 0.62)
        )

        // Right curves (mirrored)
        let curveR = NSBezierPath()
        curveR.move(to: NSPoint(x: cx + 180 + offset, y: startY))
        curveR.curve(
            to: NSPoint(x: cx + 180 + offset, y: endY),
            controlPoint1: NSPoint(x: cx + 250 + offset * 1.5, y: size * 0.38),
            controlPoint2: NSPoint(x: cx + 110 + offset * 0.5, y: size * 0.62)
        )

        NSColor(white: 1.0, alpha: alpha).setStroke()
        curve.lineWidth = lineWidth
        curve.lineCapStyle = .round
        curve.stroke()
        curveR.lineWidth = lineWidth
        curveR.lineCapStyle = .round
        curveR.stroke()
    }

    // === Mouse shadow (soft, offset) ===
    let mw = 260.0, mh = 440.0
    let mx = cx - mw / 2, my = (size - mh) / 2 - 15
    for s in stride(from: 20.0, through: 2.0, by: -2.0) {
        let shadowRect = NSRect(x: mx + s * 0.4, y: my - s * 0.8, width: mw, height: mh)
        let shadowPath = NSBezierPath(roundedRect: shadowRect, xRadius: mw / 2, yRadius: mw / 2)
        NSColor(white: 0.0, alpha: 0.012).setFill()
        shadowPath.fill()
    }

    // === Mouse body ===
    let mouseRect = NSRect(x: mx, y: my, width: mw, height: mh)
    let mousePath = NSBezierPath(roundedRect: mouseRect, xRadius: mw / 2, yRadius: mw / 2)

    // Body gradient (subtle 3D feel)
    let mouseGrad = NSGradient(colorsAndLocations:
        (NSColor(white: 1.0, alpha: 1.0), 0.0),
        (NSColor(white: 0.97, alpha: 1.0), 0.4),
        (NSColor(white: 0.91, alpha: 1.0), 1.0)
    )!
    mouseGrad.draw(in: mousePath, angle: 90)

    // Mouse edge highlight
    NSColor(white: 0.85, alpha: 0.6).setStroke()
    mousePath.lineWidth = 1.5
    mousePath.stroke()

    // === Divider line ===
    let divY = my + mh * 0.55
    let divLine = NSBezierPath()
    divLine.move(to: NSPoint(x: mx + 25, y: divY))
    divLine.line(to: NSPoint(x: mx + mw - 25, y: divY))
    NSColor(white: 0.80, alpha: 0.8).setStroke()
    divLine.lineWidth = 2
    divLine.stroke()

    // === Scroll wheel with glow ===
    let ww = 34.0, wh = 65.0
    let wx = cx - ww / 2, wy = divY + 28

    // Glow behind wheel
    let glowRect = NSRect(x: wx - 15, y: wy - 15, width: ww + 30, height: wh + 30)
    let glowPath = NSBezierPath(roundedRect: glowRect, xRadius: (ww + 30) / 2, yRadius: (ww + 30) / 2)
    NSColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 0.25).setFill()
    glowPath.fill()

    // Wheel body
    let wheelRect = NSRect(x: wx, y: wy, width: ww, height: wh)
    let wheelPath = NSBezierPath(roundedRect: wheelRect, xRadius: ww / 2, yRadius: ww / 2)
    let wheelGrad = NSGradient(colors: [
        NSColor(red: 0.40, green: 0.65, blue: 1.0, alpha: 0.9),
        NSColor(red: 0.25, green: 0.50, blue: 0.95, alpha: 0.9),
    ])!
    wheelGrad.draw(in: wheelPath, angle: 90)

    // Wheel notch lines
    NSColor(white: 1.0, alpha: 0.45).setStroke()
    for i in 0..<3 {
        let ly = wy + 16 + Double(i) * 16
        let notch = NSBezierPath()
        notch.move(to: NSPoint(x: wx + 9, y: ly))
        notch.line(to: NSPoint(x: wx + ww - 9, y: ly))
        notch.lineWidth = 1.8
        notch.lineCapStyle = .round
        notch.stroke()
    }

    // === Small motion arrows (scroll direction indicator) ===
    let arrowColor = NSColor(white: 1.0, alpha: 0.35)
    arrowColor.setStroke()
    arrowColor.setFill()

    // Down arrow below mouse
    let ay = my - 30
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: cx - 18, y: ay))
    arrow.line(to: NSPoint(x: cx, y: ay - 22))
    arrow.line(to: NSPoint(x: cx + 18, y: ay))
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.stroke()

    // Up arrow above mouse
    let ay2 = my + mh + 30
    let arrow2 = NSBezierPath()
    arrow2.move(to: NSPoint(x: cx - 18, y: ay2))
    arrow2.line(to: NSPoint(x: cx, y: ay2 + 22))
    arrow2.line(to: NSPoint(x: cx + 18, y: ay2))
    arrow2.lineWidth = 4
    arrow2.lineCapStyle = .round
    arrow2.lineJoinStyle = .round
    arrow2.stroke()

    return true
}

// Save 1024x1024 PNG
guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    print("Failed"); exit(1)
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! pngData.write(to: URL(fileURLWithPath: outPath))
print("Saved: \(outPath)")

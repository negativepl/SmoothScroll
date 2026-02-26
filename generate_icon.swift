import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    NSGraphicsContext.current?.imageInterpolation = .high

    // Rounded rect background with gradient
    let bgRect = rect.insetBy(dx: 40, dy: 40)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 190, yRadius: 190)

    let gradient = NSGradient(colors: [
        NSColor(red: 0.30, green: 0.58, blue: 1.0, alpha: 1.0),
        NSColor(red: 0.18, green: 0.38, blue: 0.92, alpha: 1.0),
    ])!
    gradient.draw(in: bgPath, angle: -45)

    // Subtle inner shadow / border
    NSColor(white: 1.0, alpha: 0.15).setStroke()
    bgPath.lineWidth = 3
    bgPath.stroke()

    // Mouse body (white, pill shape)
    let mw = 280.0, mh = 480.0
    let mx = (size - mw) / 2, my = (size - mh) / 2 - 20
    let mouseRect = NSRect(x: mx, y: my, width: mw, height: mh)
    let mousePath = NSBezierPath(roundedRect: mouseRect, xRadius: mw / 2, yRadius: mw / 2)

    // Mouse shadow
    let shadowRect = NSRect(x: mx + 8, y: my - 12, width: mw, height: mh)
    let shadowPath = NSBezierPath(roundedRect: shadowRect, xRadius: mw / 2, yRadius: mw / 2)
    NSColor(white: 0.0, alpha: 0.15).setFill()
    shadowPath.fill()

    // Mouse body fill
    let mouseGradient = NSGradient(colors: [
        NSColor(white: 1.0, alpha: 1.0),
        NSColor(white: 0.92, alpha: 1.0),
    ])!
    mouseGradient.draw(in: mousePath, angle: 90)

    // Divider line
    let divY = my + mh * 0.55
    let line = NSBezierPath()
    line.move(to: NSPoint(x: mx + 30, y: divY))
    line.line(to: NSPoint(x: mx + mw - 30, y: divY))
    NSColor(white: 0.82, alpha: 1.0).setStroke()
    line.lineWidth = 3
    line.stroke()

    // Scroll wheel
    let ww = 36.0, wh = 70.0
    let wx = (size - ww) / 2, wy = divY + 30
    let wheelRect = NSRect(x: wx, y: wy, width: ww, height: wh)
    let wheelPath = NSBezierPath(roundedRect: wheelRect, xRadius: ww / 2, yRadius: ww / 2)
    NSColor(red: 0.30, green: 0.58, blue: 1.0, alpha: 0.7).setFill()
    wheelPath.fill()

    // Scroll lines on wheel (indicating smooth scroll)
    NSColor(white: 1.0, alpha: 0.5).setStroke()
    for i in 0..<3 {
        let ly = wy + 18 + Double(i) * 16
        let scrollLine = NSBezierPath()
        scrollLine.move(to: NSPoint(x: wx + 8, y: ly))
        scrollLine.line(to: NSPoint(x: wx + ww - 8, y: ly))
        scrollLine.lineWidth = 2
        scrollLine.stroke()
    }

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

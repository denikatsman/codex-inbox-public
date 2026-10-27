import AppKit

// Original envelope artwork, drawn as paths so the app icon is independent of SF Symbols.
let dir = CommandLine.arguments[1]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let side = CGFloat(pixels)
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let tile = NSBezierPath(roundedRect: NSRect(x: side * 0.06, y: side * 0.06, width: side * 0.88, height: side * 0.88), xRadius: side * 0.20, yRadius: side * 0.20)
        NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.42, blue: 0.42, alpha: 1), ending: NSColor(calibratedRed: 0.07, green: 0.21, blue: 0.27, alpha: 1))!.draw(in: tile, angle: 90)

        let envelope = NSBezierPath(roundedRect: NSRect(x: side * 0.22, y: side * 0.28, width: side * 0.56, height: side * 0.40), xRadius: side * 0.045, yRadius: side * 0.045)
        NSColor.white.setFill()
        envelope.fill()
        let fold = NSBezierPath()
        fold.move(to: NSPoint(x: side * 0.24, y: side * 0.64))
        fold.line(to: NSPoint(x: side * 0.50, y: side * 0.45))
        fold.line(to: NSPoint(x: side * 0.76, y: side * 0.64))
        fold.lineWidth = side * 0.035
        fold.lineCapStyle = .round
        fold.lineJoinStyle = .round
        NSColor(calibratedRed: 0.10, green: 0.31, blue: 0.34, alpha: 1).setStroke()
        fold.stroke()
        NSColor(calibratedRed: 0.53, green: 0.97, blue: 0.77, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: side * 0.69, y: side * 0.65, width: side * 0.15, height: side * 0.15)).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir + "/icon_\(size)x\(size)\(suffix).png"))
    }
}

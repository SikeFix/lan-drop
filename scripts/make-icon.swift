import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func draw(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    let rect = NSRect(x: 80, y: 80, width: 864, height: 864)
    let background = NSBezierPath(roundedRect: rect, xRadius: 198, yRadius: 198)
    NSGradient(starting: NSColor(calibratedRed: 0.09, green: 0.61, blue: 0.62, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.36, blue: 0.70, alpha: 1))!
        .draw(in: background, angle: -45)
    let top = NSBezierPath()
    top.move(to: NSPoint(x: 270, y: 630))
    top.line(to: NSPoint(x: 728, y: 630))
    top.move(to: NSPoint(x: 614, y: 744))
    top.line(to: NSPoint(x: 728, y: 630))
    top.line(to: NSPoint(x: 614, y: 516))
    top.lineWidth = 62
    top.lineCapStyle = .round
    top.lineJoinStyle = .round
    NSColor.white.setStroke()
    top.stroke()
    let bottom = NSBezierPath()
    bottom.move(to: NSPoint(x: 754, y: 382))
    bottom.line(to: NSPoint(x: 296, y: 382))
    bottom.move(to: NSPoint(x: 410, y: 496))
    bottom.line(to: NSPoint(x: 296, y: 382))
    bottom.line(to: NSPoint(x: 410, y: 268))
    bottom.lineWidth = 62
    bottom.lineCapStyle = .round
    bottom.lineJoinStyle = .round
    NSColor(calibratedWhite: 1, alpha: 0.72).setStroke()
    bottom.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size: size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size: size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

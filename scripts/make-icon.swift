// Renders the Claudebar app icon (1024×1024 PNG): a glowing spark under a notch.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Squircle tile on the standard macOS icon grid.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
context.saveGState()
context.addPath(CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil))
context.clip()
let background = CGGradient(colorsSpace: space, colors: [color(0x221D2B), color(0x0A090D)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Warm bloom behind the spark.
let center = CGPoint(x: 512, y: 470)
let bloom = CGGradient(colorsSpace: space, colors: [color(0xF28F66, 0.55), color(0xB08CFF, 0.18), color(0x000000, 0)] as CFArray,
                       locations: [0, 0.45, 1])!
context.drawRadialGradient(bloom, startCenter: center, startRadius: 0, endCenter: center, endRadius: 360, options: [])

// The notch, hanging from the top edge, with a thin glowing rim.
let notch = CGRect(x: 322, y: 794, width: 380, height: 150)
let notchPath = CGPath(roundedRect: notch, cornerWidth: 60, cornerHeight: 60, transform: nil)
context.setShadow(offset: .zero, blur: 40, color: color(0xF28F66, 0.9))
context.addPath(notchPath)
context.setStrokeColor(color(0xF6A27E))
context.setLineWidth(6)
context.strokePath()
context.setShadow(offset: .zero, blur: 0, color: nil)
context.addPath(notchPath)
context.setFillColor(color(0x000000))
context.fillPath()
context.restoreGState()

// Spark rays with a coral → violet gradient.
let rays: [CGFloat] = [1.0, 0.64, 0.9, 0.7, 0.97, 0.6, 0.86, 0.68, 0.94, 0.62, 0.88, 0.74]
let radius: CGFloat = 250
let sparkPath = CGMutablePath()
for (index, length) in rays.enumerated() {
    let angle = CGFloat(index) / CGFloat(rays.count) * 2 * .pi + 0.2
    sparkPath.move(to: CGPoint(x: center.x, y: center.y))
    sparkPath.addLine(to: CGPoint(x: center.x + cos(angle) * radius * length, y: center.y + sin(angle) * radius * length))
}
let stroked = sparkPath.copy(strokingWithWidth: 50, lineCap: .round, lineJoin: .round, miterLimit: 1)

context.saveGState()
context.setShadow(offset: .zero, blur: 50, color: color(0xF28F66, 0.85))
context.addPath(stroked)
context.setFillColor(color(0xF28F66))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(stroked)
context.clip()
let sparkGradient = CGGradient(colorsSpace: space, colors: [color(0xFFB08A), color(0xF28F66), color(0xB08CFF)] as CFArray,
                               locations: [0, 0.5, 1])!
context.drawLinearGradient(sparkGradient, start: CGPoint(x: 512, y: 740), end: CGPoint(x: 512, y: 200), options: [])
context.restoreGState()

let image = context.makeImage()!
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: output))

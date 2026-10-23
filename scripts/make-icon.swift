// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // macOS icon grid: 824pt body centred in 1024 with a continuous-corner rounded rect.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.10, green: 0.12, blue: 0.20, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.05, green: 0.27, blue: 0.36, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Soft highlight at the top for a glassy feel.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 380 * s, y: 860 * s), startRadius: 0,
                           endCenter: CGPoint(x: 380 * s, y: 860 * s), endRadius: 620 * s, options: [])

    // The tether: a curved line from the prompt to an anchor point.
    let accent = NSColor(srgbRed: 0.35, green: 0.88, blue: 0.80, alpha: 1)
    ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
    ctx.setLineWidth(22 * s)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 590 * s, y: 312 * s))
    ctx.addCurve(to: CGPoint(x: 760 * s, y: 720 * s),
                 control1: CGPoint(x: 790 * s, y: 312 * s), control2: CGPoint(x: 640 * s, y: 690 * s))
    ctx.strokePath()
    ctx.setFillColor(accent.cgColor)
    ctx.fillEllipse(in: CGRect(x: 718 * s, y: 678 * s, width: 84 * s, height: 84 * s))
    ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.16, blue: 0.24, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: 742 * s, y: 702 * s, width: 36 * s, height: 36 * s))
    ctx.restoreGState()

    // The prompt ">_"
    let font = NSFont.monospacedSystemFont(ofSize: 300 * s, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    NSAttributedString(string: ">_", attributes: attrs).draw(at: CGPoint(x: 205 * s, y: 285 * s))

    img.unlockFocus()
    return img
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        render(size: px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print("Wrote \(out.path)")

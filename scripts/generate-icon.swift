#!/usr/bin/env swift
import Cocoa
import CoreGraphics

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-icon.swift <output.iconset>\n", stderr)
    exit(1)
}

let iconsetPath = CommandLine.arguments[1]
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> NSImage {
    let size = CGFloat(pixelSize)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)
    cg.interpolationQuality = .high

    // macOS standard icon inset (~9.8% padding around squircle)
    let pad = size * 0.095
    let cardRect = CGRect(x: pad, y: pad, width: size - 2 * pad, height: size - 2 * pad)
    let cornerRadius = cardRect.width * 0.225

    // Drop shadow behind squircle
    cg.saveGState()
    cg.setShadow(
        offset: CGSize(width: 0, height: -size * 0.02),
        blur: size * 0.04,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
    )
    let squircle = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    cg.addPath(squircle)
    cg.setFillColor(CGColor(red: 0.07, green: 0.11, blue: 0.22, alpha: 1.0))
    cg.fillPath()
    cg.restoreGState()

    // Clip to squircle for rich layered background
    cg.saveGState()
    cg.addPath(squircle)
    cg.clip()

    // Deep navy -> electric cobalt base gradient
    let cs = CGColorSpaceCreateDeviceRGB()
    let bgGrad = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 0.06, green: 0.10, blue: 0.24, alpha: 1.0),
            CGColor(red: 0.09, green: 0.26, blue: 0.62, alpha: 1.0),
            CGColor(red: 0.11, green: 0.48, blue: 0.92, alpha: 1.0)
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    cg.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: cardRect.minX, y: cardRect.minY),
        end: CGPoint(x: cardRect.maxX, y: cardRect.maxY),
        options: []
    )

    // Warm orange-amber ambient glow in lower-right (Rufus energy!)
    let warmGlow = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1.0, green: 0.48, blue: 0.14, alpha: 0.65),
            CGColor(red: 1.0, green: 0.38, blue: 0.10, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    cg.drawRadialGradient(
        warmGlow,
        startCenter: CGPoint(x: cardRect.maxX - cardRect.width * 0.22, y: cardRect.minY + cardRect.height * 0.22),
        startRadius: 0,
        endCenter: CGPoint(x: cardRect.maxX - cardRect.width * 0.22, y: cardRect.minY + cardRect.height * 0.22),
        endRadius: cardRect.width * 0.55,
        options: []
    )

    // Subtle top specular highlight
    let topSheen = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    cg.drawLinearGradient(
        topSheen,
        start: CGPoint(x: cardRect.midX, y: cardRect.maxY),
        end: CGPoint(x: cardRect.midX, y: cardRect.midY + cardRect.height * 0.05),
        options: []
    )

    // --- Stylized USB Flash Drive ---
    let cx = cardRect.midX - cardRect.width * 0.03
    let cy = cardRect.midY

    // USB metallic connector (top)
    let plugW = cardRect.width * 0.25
    let plugH = cardRect.height * 0.18
    let plugRect = CGRect(x: cx - plugW / 2, y: cy + cardRect.height * 0.15, width: plugW, height: plugH)
    let plugPath = CGPath(roundedRect: plugRect, cornerWidth: size * 0.025, cornerHeight: size * 0.025, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -size * 0.015), blur: size * 0.03, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.3))
    cg.addPath(plugPath)
    cg.clip()
    let metalGrad = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 0.72, green: 0.77, blue: 0.85, alpha: 1.0),
            CGColor(red: 0.96, green: 0.98, blue: 1.0, alpha: 1.0),
            CGColor(red: 0.68, green: 0.74, blue: 0.82, alpha: 1.0)
        ] as CFArray,
        locations: [0.0, 0.45, 1.0]
    )!
    cg.drawLinearGradient(metalGrad, start: CGPoint(x: plugRect.minX, y: plugRect.midY), end: CGPoint(x: plugRect.maxX, y: plugRect.midY), options: [])
    cg.restoreGState()

    // Two dark rectangular USB plug cutouts
    let holeW = plugW * 0.22
    let holeH = plugH * 0.34
    let holeY = plugRect.minY + plugH * 0.36
    let hole1 = CGRect(x: cx - plugW * 0.28, y: holeY, width: holeW, height: holeH)
    let hole2 = CGRect(x: cx + plugW * 0.06, y: holeY, width: holeW, height: holeH)
    cg.setFillColor(CGColor(red: 0.15, green: 0.20, blue: 0.32, alpha: 0.85))
    cg.addPath(CGPath(roundedRect: hole1, cornerWidth: size * 0.008, cornerHeight: size * 0.008, transform: nil))
    cg.addPath(CGPath(roundedRect: hole2, cornerWidth: size * 0.008, cornerHeight: size * 0.008, transform: nil))
    cg.fillPath()

    // USB Drive Body (sleek white-silver frosted capsule)
    let bodyW = cardRect.width * 0.42
    let bodyH = cardRect.height * 0.50
    let bodyRect = CGRect(x: cx - bodyW / 2, y: cy - bodyH * 0.66, width: bodyW, height: bodyH)
    let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: size * 0.06, cornerHeight: size * 0.06, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -size * 0.025), blur: size * 0.045, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
    cg.addPath(bodyPath)
    cg.setFillColor(CGColor(red: 0.95, green: 0.97, blue: 1.0, alpha: 1.0))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(bodyPath)
    cg.clip()
    let bodyGrad = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 0.86, green: 0.90, blue: 0.97, alpha: 1.0),
            CGColor(red: 0.98, green: 0.99, blue: 1.0, alpha: 1.0),
            CGColor(red: 0.82, green: 0.88, blue: 0.96, alpha: 1.0)
        ] as CFArray,
        locations: [0.0, 0.38, 1.0]
    )!
    cg.drawLinearGradient(bodyGrad, start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY), end: CGPoint(x: bodyRect.maxX, y: bodyRect.minY), options: [])
    cg.restoreGState()

    // Subtle glowing blue status LED bar on USB body
    let ledW = bodyW * 0.36
    let ledH = bodyH * 0.06
    let ledRect = CGRect(x: cx - ledW / 2, y: bodyRect.maxY - bodyH * 0.24, width: ledW, height: ledH)
    cg.setFillColor(CGColor(red: 0.14, green: 0.58, blue: 1.0, alpha: 0.95))
    cg.addPath(CGPath(roundedRect: ledRect, cornerWidth: ledH / 2, cornerHeight: ledH / 2, transform: nil))
    cg.fillPath()

    // Minimalist Windows-style 4-pane glyph subtly etched on USB body
    let paneSize = bodyW * 0.14
    let gap = bodyW * 0.04
    let gridStartX = cx - paneSize - gap / 2
    let gridStartY = bodyRect.minY + bodyH * 0.24
    cg.setFillColor(CGColor(red: 0.13, green: 0.44, blue: 0.90, alpha: 0.88))
    for row in 0..<2 {
        for col in 0..<2 {
            let r = CGRect(
                x: gridStartX + CGFloat(col) * (paneSize + gap),
                y: gridStartY + CGFloat(row) * (paneSize + gap),
                width: paneSize,
                height: paneSize
            )
            cg.addPath(CGPath(roundedRect: r, cornerWidth: paneSize * 0.2, cornerHeight: paneSize * 0.2, transform: nil))
        }
    }
    cg.fillPath()

    // --- Glowing Ember-Orange Lightning Badge (bottom-right) ---
    let badgeRadius = cardRect.width * 0.175
    let badgeCenter = CGPoint(x: bodyRect.maxX + cardRect.width * 0.02, y: bodyRect.minY + cardRect.height * 0.09)
    let badgeRect = CGRect(
        x: badgeCenter.x - badgeRadius,
        y: badgeCenter.y - badgeRadius,
        width: badgeRadius * 2,
        height: badgeRadius * 2
    )
    let badgePath = CGPath(ellipseIn: badgeRect, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -size * 0.015), blur: size * 0.035, color: CGColor(red: 0.95, green: 0.32, blue: 0.08, alpha: 0.55))
    cg.addPath(badgePath)
    cg.setFillColor(CGColor(red: 0.99, green: 0.45, blue: 0.12, alpha: 1.0))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(badgePath)
    cg.clip()
    let badgeGrad = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1.0, green: 0.66, blue: 0.16, alpha: 1.0),
            CGColor(red: 0.95, green: 0.30, blue: 0.14, alpha: 1.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    cg.drawLinearGradient(badgeGrad, start: CGPoint(x: badgeRect.minX, y: badgeRect.maxY), end: CGPoint(x: badgeRect.maxX, y: badgeRect.minY), options: [])
    cg.restoreGState()

    // Crisp white lightning bolt inside orange badge
    let bolt = CGMutablePath()
    let r = badgeRadius * 0.58
    bolt.move(to: CGPoint(x: badgeCenter.x + r * 0.12, y: badgeCenter.y + r * 0.92))
    bolt.addLine(to: CGPoint(x: badgeCenter.x - r * 0.56, y: badgeCenter.y - r * 0.05))
    bolt.addLine(to: CGPoint(x: badgeCenter.x - r * 0.04, y: badgeCenter.y - r * 0.05))
    bolt.addLine(to: CGPoint(x: badgeCenter.x - r * 0.18, y: badgeCenter.y - r * 0.92))
    bolt.addLine(to: CGPoint(x: badgeCenter.x + r * 0.56, y: badgeCenter.y + r * 0.10))
    bolt.addLine(to: CGPoint(x: badgeCenter.x + r * 0.04, y: badgeCenter.y + r * 0.10))
    bolt.closeSubpath()
    cg.addPath(bolt)
    cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1.0))
    cg.fillPath()

    // Hairline glass inner border on squircle
    cg.addPath(squircle)
    cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    cg.setLineWidth(max(1.0, size * 0.008))
    cg.strokePath()

    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    let img = NSImage(size: NSSize(width: size, height: size))
    img.addRepresentation(rep)
    return img
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in specs {
    let img = renderIcon(pixelSize: px)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fputs("Failed encoding \(filename)\n", stderr)
        exit(1)
    }
    let outURL = URL(fileURLWithPath: iconsetPath).appendingPathComponent(filename)
    try png.write(to: outURL)
}

print("Generated iconset at \(iconsetPath)")

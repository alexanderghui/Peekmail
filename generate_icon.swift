#!/usr/bin/env swift

import AppKit
import CoreGraphics

func generateIcon(pixelSize: Int) -> Data? {
    let s = CGFloat(pixelSize)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil,
                                  width: pixelSize,
                                  height: pixelSize,
                                  bitsPerComponent: 8,
                                  bytesPerRow: pixelSize * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }

    // === Background: Fill entire square ===
    context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0))
    context.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // Gradient on top
    let gradientColors = [
        CGColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1.0),
        CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0),
    ] as CFArray
    let locations: [CGFloat] = [0.0, 1.0]

    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: locations) {
        context.drawLinearGradient(gradient,
            start: CGPoint(x: s/2, y: s),
            end: CGPoint(x: s/2, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // === Envelope dimensions ===
    let envMarginX = s * 0.20
    let envTop = s * 0.69
    let envBottom = s * 0.31
    let envLeft = envMarginX
    let envRight = s - envMarginX
    let envCorner = s * 0.04
    let lineWidth = s * 0.025
    let flapMidX = s * 0.5

    // === Envelope outline (body) ===
    let envRect = CGRect(x: envLeft, y: envBottom, width: envRight - envLeft, height: envTop - envBottom)
    let envPath = CGPath(roundedRect: envRect, cornerWidth: envCorner, cornerHeight: envCorner, transform: nil)

    context.saveGState()
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    context.setLineWidth(lineWidth)
    context.setLineJoin(.round)
    context.addPath(envPath)
    context.strokePath()
    context.restoreGState()

    // === Closed flap (V pointing down from top edge) ===
    let flapPath = CGMutablePath()
    flapPath.move(to: CGPoint(x: envLeft + s*0.03, y: envTop - s*0.01))
    flapPath.addLine(to: CGPoint(x: flapMidX, y: (envTop + envBottom) / 2 + s*0.06))
    flapPath.addLine(to: CGPoint(x: envRight - s*0.03, y: envTop - s*0.01))

    context.saveGState()
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(flapPath)
    context.strokePath()
    context.restoreGState()

    // Create PNG data
    guard let cgImage = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

let outputDir = "/Users/alex_hui/Documents/Projects/Peekmail/Peekmail/Assets.xcassets/AppIcon.appiconset"

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
    ("icon_1024x1024.png",  1024),
]

print("Generating Peekmail app icons...")
for size in sizes {
    if let data = generateIcon(pixelSize: size.pixels) {
        let path = "\(outputDir)/\(size.name)"
        try! data.write(to: URL(fileURLWithPath: path))
        print("  Saved: \(path) (\(size.pixels)x\(size.pixels))")
    }
}

print("Done! All icons generated.")

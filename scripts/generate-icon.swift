#!/usr/bin/env swift
import AppKit

// Rebuild the source artwork: swift scripts/generate-icon.swift
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let tile = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832), xRadius: 184, yRadius: 184)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.18, alpha: 1).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: NSColor(calibratedRed: 0.15, green: 0.23, blue: 0.36, alpha: 1),
    ending: NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.13, alpha: 1))!.draw(in: tile, angle: -65)
NSColor.white.withAlphaComponent(0.12).setStroke()
tile.lineWidth = 2
tile.stroke()

func stroke(_ points: [NSPoint], color: NSColor) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    path.lineWidth = 68
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
}
// Interlocking crop arms, matching the blue and white wordmark.
stroke([NSPoint(x: 246, y: 658), NSPoint(x: 674, y: 658), NSPoint(x: 674, y: 246)],
    color: NSColor(calibratedRed: 0.51, green: 0.73, blue: 1, alpha: 1))
stroke([NSPoint(x: 350, y: 778), NSPoint(x: 350, y: 350), NSPoint(x: 778, y: 350)], color: .white)
NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: "Resources/AppIcon.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("Created \(output.path)")

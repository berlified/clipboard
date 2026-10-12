#!/usr/bin/env swift
// Renders the LiveDocs app icon: black squircle + white fingerprint (touchid).
// Usage: swift scripts/render-icon.swift /tmp/livedocs-icon.png
import AppKit
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/livedocs-icon.png"
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
NSColor.black.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: S, height: S)).fill()

// Squircle body
let inset: CGFloat = 64
let body = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2),
                        xRadius: 200, yRadius: 200)
// Subtle top light for depth
let bg = NSGradient(colors: [NSColor(white: 0.16, alpha: 1.0), NSColor(white: 0.02, alpha: 1.0)])!
NSGraphicsContext.saveGraphicsState()
body.setClip()
bg.draw(in: NSRect(x: 0, y: 0, width: S, height: S), angle: 90)
NSGraphicsContext.restoreGraphicsState()
NSColor.white.withAlphaComponent(0.35).setStroke()
body.lineWidth = 6
body.stroke()

// White fingerprint glyph, centered
if let glyph = NSImage(systemSymbolName: "touchid", accessibilityDescription: "LiveDocs") {
    let tinted = NSImage(size: glyph.size)
    tinted.lockFocus()
    let r = NSRect(origin: .zero, size: glyph.size)
    glyph.draw(in: r, from: NSZeroRect, operation: .copy, fraction: 1.0)
    NSColor.white.setFill()
    r.fill(using: .sourceIn)
    tinted.unlockFocus()
    let target: CGFloat = 600
    let aspect = glyph.size.width / glyph.size.height
    let w = aspect >= 1 ? target : target * aspect
    let h = aspect >= 1 ? target / aspect : target
    tinted.draw(in: NSRect(x: (S - w) / 2, y: (S - h) / 2, width: w, height: h),
                from: NSZeroRect, operation: .sourceOver, fraction: 1.0)
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("icon render failed\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(png.count) bytes)")

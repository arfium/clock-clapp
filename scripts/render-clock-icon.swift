import AppKit
import Foundation

// clock's app icon, drawn to Apple's own measured constants.
//
// Geometry recovered from /System/Applications/Clock.app/.../ClockFace.icns, which
// ships at a true 1024×1024 — the authoritative source for the dial. Everything is
// a fraction of either the canvas or the dial radius R, so it scales cleanly.
//
// The three things that make it read as a real clock icon:
//   • The body is FULL-BLEED (fills the canvas, rounded corners), the shared clapp
//     icon standard — matching telegram/whatsapp so it reads at the same size in the
//     Clatch library. (Apple's Dock uses an ~0.80 inset for bounce headroom; the
//     Clatch library grid wants edge-to-edge, so we fill it.)
//   • The body is a vertical gradient, not flat black — a pure-black squircle loses
//     its silhouette on a dark wallpaper.
//   • ZERO tick marks, twelve upright numerals, and hour/minute hands of IDENTICAL
//     width (only length differs).
//
// Run: swift scripts/render-clock-icon.swift  (→ assets/icon.png)

let px: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high

let C = NSPoint(x: px / 2, y: px / 2)
let R = px * 0.4338                      // dial radius (scaled to the full-bleed body)
let orange = NSColor.systemOrange
let ink = NSColor.black

// ── body ────────────────────────────────────────────────────────────────────
let bodySide = px                        // full-bleed (shared clapp icon standard)
let body = NSBezierPath(roundedRect: NSRect(x: (px - bodySide) / 2, y: (px - bodySide) / 2,
                                            width: bodySide, height: bodySide),
                        xRadius: bodySide * 0.225, yRadius: bodySide * 0.225)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 40
shadow.set()
NSGradient(starting: NSColor(srgbRed: 0.184, green: 0.184, blue: 0.192, alpha: 1),
           ending: NSColor(srgbRed: 0.098, green: 0.098, blue: 0.106, alpha: 1))?
    .draw(in: body, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// ── dial: flat, slightly off-white, no gradient / vignette / stroke ─────────
NSColor(srgbRed: 0.961, green: 0.961, blue: 0.973, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: C.x - R, y: C.y - R, width: R * 2, height: R * 2)).fill()

func at(_ deg: Double, _ r: CGFloat) -> NSPoint {
    let a = CGFloat(90 - deg) * .pi / 180
    return NSPoint(x: C.x + cos(a) * r, y: C.y + sin(a) * r)
}

// ── numerals: all twelve, upright, medium ──────────────────────────────────
// Size is em = 0.27 R, which yields Apple's measured 0.190 R cap height
// (cap ≈ 0.705 × point size). Medium lands the digit widths in the measured
// 48–54px band at 1024; semibold overshoots it.
let font = NSFont.systemFont(ofSize: R * 0.27, weight: .medium)
let numeral = NSColor(srgbRed: 0.18, green: 0.18, blue: 0.18, alpha: 1)
for n in 1...12 {
    let s = NSAttributedString(string: "\(n)", attributes: [.font: font, .foregroundColor: numeral])
    let sz = s.size()
    let p = at(Double(n) / 12 * 360, R * 0.82)
    s.draw(at: NSPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
}

// ── hands, at Apple's own icon time (10:09:30, optically nudged) ────────────
func hand(_ deg: Double, len: CGFloat, w: CGFloat, tail: CGFloat, _ color: NSColor) {
    let p = NSBezierPath()
    p.move(to: at(deg + 180, tail))
    p.line(to: at(deg, len))
    p.lineWidth = w
    p.lineCapStyle = .round
    color.setStroke()
    p.stroke()
}
hand(305.5, len: R * 0.527, w: R * 0.083, tail: 0, ink)
hand(54.4, len: R * 0.911, w: R * 0.083, tail: 0, ink)
hand(180.0, len: R * 0.933, w: R * 0.023, tail: R * 0.140, orange)

// ── hub: orange ring, white centre ─────────────────────────────────────────
orange.setFill()
let hub = R * 0.034
NSBezierPath(ovalIn: NSRect(x: C.x - hub, y: C.y - hub, width: hub * 2, height: hub * 2)).fill()
NSColor.white.setFill()
let dot = R * 0.011
NSBezierPath(ovalIn: NSRect(x: C.x - dot, y: C.y - dot, width: dot * 2, height: dot * 2)).fill()

NSGraphicsContext.restoreGraphicsState()

let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("assets/icon.png")
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print(out.path)

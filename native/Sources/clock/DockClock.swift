import AppKit
import Foundation

// The live Dock icon — the most-loved crafted detail in Apple's Clock, and cheap.
//
// Apple ships this as a real `NSDockTilePlugIn` bundle, which is why their icon
// ticks even when Clock isn't running. We use the simpler public fallback
// (`NSApp.dockTile.contentView` redrawn at 1 Hz), which ticks only while we're
// open — a fair trade for not shipping a separate plug-in bundle.
//
// Geometry below is the ICON's, measured from Apple's own ClockFace.icns at
// 1024×1024, expressed as fractions so it renders at any size. Note the icon's
// hands are ~2× the width of the in-app face's (0.083 R vs 0.0417 R) — that is
// deliberate at icon scale; don't cross-apply the two sets.
@MainActor
final class DockClock {
    private var timer: Timer?
    private let view = NSImageView()

    /// Stop ticking — there is no Dock tile to draw into while we're an accessory.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func start() {
        guard timer == nil else { return }
        NSApp.dockTile.contentView = view
        redraw()
        // 1 Hz. Never 60fps: the Dock only samples when we explicitly redraw, so a
        // faster timer is pure battery burn with no visual gain.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func redraw() {
        view.image = DockClock.render(Date(), side: 256)
        NSApp.dockTile.display()
    }

    static func render(_ now: Date, side: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        defer { img.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high

        let C = NSPoint(x: side / 2, y: side / 2)
        let R = side * 0.3491                     // dial radius as a fraction of canvas
        let orange = NSColor.systemOrange
        let ink = NSColor.black

        // Body: a squircle at 0.8047 of the canvas — the remaining margin is shadow
        // and Dock-bounce headroom. Filling the canvas makes the icon read oversized
        // next to every neighbour.
        let bodySide = side * 0.8047
        let body = NSBezierPath(roundedRect: NSRect(x: (side - bodySide) / 2, y: (side - bodySide) / 2,
                                                    width: bodySide, height: bodySide),
                                xRadius: bodySide * 0.225, yRadius: bodySide * 0.225)
        NSGradient(starting: NSColor(srgbRed: 0.184, green: 0.184, blue: 0.192, alpha: 1),
                   ending: NSColor(srgbRed: 0.098, green: 0.098, blue: 0.106, alpha: 1))?
            .draw(in: body, angle: -90)

        // Dial: flat, not pure white, no gradient/vignette/stroke.
        NSColor(srgbRed: 0.961, green: 0.961, blue: 0.973, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: C.x - R, y: C.y - R, width: R * 2, height: R * 2)).fill()

        func at(_ deg: Double, _ r: CGFloat) -> NSPoint {
            let a = CGFloat(90 - deg) * .pi / 180
            return NSPoint(x: C.x + cos(a) * r, y: C.y + sin(a) * r)
        }

        // Numerals — all twelve, upright. ZERO tick marks: Apple's dial has none.
        let pt = R * 0.27
        let font = NSFont.systemFont(ofSize: pt, weight: .medium)
        let numeral = NSColor(srgbRed: 0.18, green: 0.18, blue: 0.18, alpha: 1)
        for n in 1...12 {
            let s = NSAttributedString(string: "\(n)", attributes: [
                .font: font, .foregroundColor: numeral,
            ])
            let sz = s.size()
            let p = at(Double(n) / 12 * 360, R * 0.82)
            s.draw(at: NSPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
        }

        let comp = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        let sec = Double(comp.second ?? 0)
        let min = Double(comp.minute ?? 0) + sec / 60
        let hr = Double((comp.hour ?? 0) % 12) + min / 60

        func hand(_ deg: Double, len: CGFloat, w: CGFloat, tail: CGFloat, _ color: NSColor) {
            let p = NSBezierPath()
            p.move(to: at(deg + 180, tail))
            p.line(to: at(deg, len))
            p.lineWidth = w
            p.lineCapStyle = .round
            color.setStroke()
            p.stroke()
        }
        // Hour and minute are the SAME width — only length differs.
        hand(hr / 12 * 360, len: R * 0.527, w: R * 0.083, tail: 0, ink)
        hand(min / 60 * 360, len: R * 0.911, w: R * 0.083, tail: 0, ink)
        hand(sec / 60 * 360, len: R * 0.933, w: R * 0.023, tail: R * 0.140, orange)

        // Hub: orange ring with a white centre dot.
        orange.setFill()
        let hub = R * 0.034
        NSBezierPath(ovalIn: NSRect(x: C.x - hub, y: C.y - hub, width: hub * 2, height: hub * 2)).fill()
        NSColor.white.setFill()
        let dot = R * 0.011
        NSBezierPath(ovalIn: NSRect(x: C.x - dot, y: C.y - dot, width: dot * 2, height: dot * 2)).fill()

        return img
    }
}

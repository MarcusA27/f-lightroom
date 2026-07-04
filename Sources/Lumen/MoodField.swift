// PARKED — not currently wired into the UI.
//
// A reactive mood pad: a flat card with a dot grid that swells under the
// pointer, and an optional color wash (fixed palette or the photo's own
// quadrant colors). Dragging the puck blends the corner "look" recipes into the
// live adjustments. Stripped out of the panel 2026-07-03 pending a decision on
// whether the color should be functional (signals warm/cool) or dropped
// entirely in favor of just the dots.
//
// To bring it back, in ContentView:
//   • add  @State var moodPuck = CGPoint(x: 0.5, y: 0.5)  and  @State var moodColors: [Color] = []
//   • place  MoodField(puck: $moodPuck, tint: fillTint, colors: moodColors) { adj = $0; updatePreview(live: $1) }
//   • have the photo-load task compute quadrantMoodColors(of:) and reset moodPuck/moodColors on load & revert.

import SwiftUI
import CoreImage

// MARK: - Mood field

// One corner of the mood pad: a named look, its glow color, and where it sits.
struct MoodAnchor {
    let at: CGPoint
    let name: String
    let glow: Color
    let adj: Adjustments
}

let moodAnchors: [MoodAnchor] = [
    MoodAnchor(at: CGPoint(x: 0, y: 0), name: "FROST",
               glow: Color(red: 0.52, green: 0.76, blue: 1.0),
               adj: Adjustments(temperature: -45, tint: -6, contrast: 16, highlights: -6, shadows: 8, saturation: -12)),
    MoodAnchor(at: CGPoint(x: 1, y: 0), name: "EMBER",
               glow: Color(red: 1.0, green: 0.62, blue: 0.26),
               adj: Adjustments(temperature: 48, tint: 8, contrast: 20, highlights: -12, shadows: -4, saturation: 22)),
    MoodAnchor(at: CGPoint(x: 0, y: 1), name: "FADED",
               glow: Color(red: 0.62, green: 0.66, blue: 0.78),
               adj: Adjustments(temperature: -14, tint: 4, contrast: -26, highlights: -18, shadows: 34, saturation: -22)),
    MoodAnchor(at: CGPoint(x: 1, y: 1), name: "SUN",
               glow: Color(red: 1.0, green: 0.82, blue: 0.45),
               adj: Adjustments(temperature: 34, contrast: -8, highlights: -14, shadows: 20, saturation: 14)),
]

// Blend the corner looks by inverse-distance to the puck, then scale by how far
// it sits from center — neutral in the middle, full character toward the edges.
func moodAdjustments(at p: CGPoint) -> Adjustments {
    var t = 0.0, ti = 0.0, c = 0.0, hi = 0.0, sh = 0.0, sa = 0.0, wsum = 0.0
    for a in moodAnchors {
        let dx = Double(p.x - a.at.x), dy = Double(p.y - a.at.y)
        let w = 1.0 / (dx * dx + dy * dy + 0.03)
        wsum += w
        t += w * a.adj.temperature; ti += w * a.adj.tint; c += w * a.adj.contrast
        hi += w * a.adj.highlights;  sh += w * a.adj.shadows; sa += w * a.adj.saturation
    }
    let dist = Double(hypot(p.x - 0.5, p.y - 0.5))
    let x = min(1, dist / 0.5)
    let k = x * x * (3 - 2 * x)   // smoothstep intensity ramp
    func v(_ s: Double) -> Double { (s / wsum * k).rounded() }
    return Adjustments(temperature: v(t), tint: v(ti), exposure: 0,
                       contrast: v(c), highlights: v(hi), shadows: v(sh), saturation: v(sa))
}

// A draggable puck over a glowing pad. Wandering it rewrites the adjustments so
// the photo morphs between moods; snapping home / hitting a mood ticks.
struct MoodField: View {
    @Binding var puck: CGPoint
    var tint: Color
    var colors: [Color] = []
    var onEdit: (Adjustments, Bool) -> Void

    @State private var prevZone = -1
    // Latest pointer position over the pad (hover or drag), normalized; nil when
    // the cursor is away. Drives the dot swell.
    @State private var activePoint: CGPoint?
    @State private var dragging = false

    private func tap(_ p: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now)
    }

    // Corner colors blended across the pad — the photo's own quadrant colors
    // when available, else a fixed airy palette.
    @ViewBuilder private var moodGradient: some View {
        let fallback = [Color(red: 0.66, green: 0.80, blue: 0.98),
                        Color(red: 0.99, green: 0.70, blue: 0.62),
                        Color(red: 0.78, green: 0.80, blue: 0.90),
                        Color(red: 0.99, green: 0.84, blue: 0.70)]
        let c = colors.count == 4 ? colors : fallback
        if #available(macOS 15.0, *) {
            MeshGradient(
                width: 2, height: 2,
                points: [.init(0, 0), .init(1, 0), .init(0, 1), .init(1, 1)],
                colors: c)
        } else {
            LinearGradient(colors: [c[0], c[3]], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var body: some View {
        let shape = Rectangle()
        return ZStack {
                // Same flat, subtle card as the histogram so it belongs.
                shape.fill(Color.primary.opacity(0.04))

                // A whisper of the 4-corner mood color — present, never loud.
                moodGradient
                    .opacity(0.3)
                    .clipShape(shape)

                // Dot field: each dot swells and brightens near the pointer.
                Canvas { ctx, size in
                    let spacing: CGFloat = 16
                    let inset: CGFloat = 10
                    let cols = max(2, Int((size.width - inset * 2) / spacing) + 1)
                    let rows = max(2, Int((size.height - inset * 2) / spacing) + 1)
                    let stepX = (size.width - inset * 2) / CGFloat(cols - 1)
                    let stepY = (size.height - inset * 2) / CGFloat(rows - 1)
                    let ap = activePoint.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                    let influence: CGFloat = 56
                    for r in 0..<rows {
                        for c in 0..<cols {
                            let x = inset + CGFloat(c) * stepX
                            let y = inset + CGFloat(r) * stepY
                            var bump: CGFloat = 0
                            if let ap {
                                let t = max(0, 1 - hypot(x - ap.x, y - ap.y) / influence)
                                bump = t * t * (3 - 2 * t)
                            }
                            let radius = 1.3 + bump * 1.3
                            let alpha = 0.3 + bump * 0.5
                            ctx.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                                            width: radius * 2, height: radius * 2)),
                                     with: .color(.primary.opacity(alpha)))
                        }
                    }
                }
                .clipShape(shape)
            }
            .contentShape(shape)
            // AppKit tracker: hover swells the dots, press/drag edits the mood
            // (and blocks window-drag, since the window is movable-by-background).
            .overlay(
                PadInteraction(
                    onHover: { fx, fy in if !dragging { activePoint = CGPoint(x: fx, y: fy) } },
                    onExit: { if !dragging { activePoint = nil } },
                    onChange: { fx, fy in
                        dragging = true
                        activePoint = CGPoint(x: fx, y: fy)
                        apply(fx, fy, live: true)
                    },
                    onEnded: {
                        dragging = false
                        apply(puck.x, puck.y, live: false)
                    }
                )
            )
    }

    private func apply(_ fx: CGFloat, _ fy: CGFloat, live: Bool) {
        var p = CGPoint(x: fx, y: fy)
        if hypot(p.x - 0.5, p.y - 0.5) < 0.07 { p = CGPoint(x: 0.5, y: 0.5) }

        let zone = zoneFor(p)
        if zone != prevZone {
            if zone == 0 { tap(.levelChange) } else if zone > 0 { tap(.alignment) }
        }
        prevZone = live ? zone : -1
        puck = p
        onEdit(moodAdjustments(at: p), live)
    }

    // 0 = snapped home, 1…n = within a mood's sweet spot, -1 = open field.
    private func zoneFor(_ p: CGPoint) -> Int {
        if p.x == 0.5 && p.y == 0.5 { return 0 }
        for (i, a) in moodAnchors.enumerated() where hypot(p.x - a.at.x, p.y - a.at.y) < 0.16 {
            return i + 1
        }
        return -1
    }
}

// 2D press/drag/hover tracker reporting normalized (x, y) with a top-left
// origin. Blocks window-drag so the pad captures the gesture, and tracks the
// pointer even while merely hovering.
struct PadInteraction: NSViewRepresentable {
    var onHover: (CGFloat, CGFloat) -> Void
    var onExit: () -> Void
    var onChange: (CGFloat, CGFloat) -> Void
    var onEnded: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = PadView(); v.configure(onHover, onExit, onChange, onEnded); return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PadView)?.configure(onHover, onExit, onChange, onEnded)
    }

    final class PadView: NSView {
        private var onHover: ((CGFloat, CGFloat) -> Void)?
        private var onExit: (() -> Void)?
        private var onChange: ((CGFloat, CGFloat) -> Void)?
        private var onEnded: (() -> Void)?

        func configure(_ h: @escaping (CGFloat, CGFloat) -> Void, _ x: @escaping () -> Void,
                       _ c: @escaping (CGFloat, CGFloat) -> Void, _ e: @escaping () -> Void) {
            onHover = h; onExit = x; onChange = c; onEnded = e
        }

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                owner: self))
        }

        private func norm(_ event: NSEvent) -> (CGFloat, CGFloat) {
            let p = convert(event.locationInWindow, from: nil)
            return (max(0, min(1, p.x / max(1, bounds.width))),
                    max(0, min(1, p.y / max(1, bounds.height))))
        }

        override func mouseMoved(with event: NSEvent)   { let (x, y) = norm(event); onHover?(x, y) }
        override func mouseEntered(with event: NSEvent)  { let (x, y) = norm(event); onHover?(x, y) }
        override func mouseExited(with event: NSEvent)   { onExit?() }
        override func mouseDown(with event: NSEvent)     { let (x, y) = norm(event); onChange?(x, y) }
        override func mouseDragged(with event: NSEvent)  { let (x, y) = norm(event); onChange?(x, y) }
        override func mouseUp(with event: NSEvent)       { onEnded?() }
    }
}

// Average color of each image quadrant, softened to an airy pastel — used to
// paint the mood pad in the photo's own colors. Order: TL, TR, BL, BR.
func quadrantMoodColors(of image: NSImage) -> [RGB]? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let cg = bitmap.cgImage else { return nil }
    let ci = CIImage(cgImage: cg)
    let e = ci.extent
    let hw = e.width / 2, hh = e.height / 2
    // CIImage origin is bottom-left, so the top row of the pad reads the top
    // (higher-y) band of the image.
    let rects = [
        CGRect(x: e.minX,      y: e.minY + hh, width: hw, height: hh),
        CGRect(x: e.minX + hw, y: e.minY + hh, width: hw, height: hh),
        CGRect(x: e.minX,      y: e.minY,      width: hw, height: hh),
        CGRect(x: e.minX + hw, y: e.minY,      width: hw, height: hh),
    ]
    let context = CIContext(options: [.workingColorSpace: NSNull()])
    var out: [RGB] = []
    for r in rects {
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: r)
        ]), let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        let base = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                           blue: CGFloat(pixel[2]) / 255, alpha: 1).usingColorSpace(.sRGB)
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        base?.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
        let airy = NSColor(hue: h,
                           saturation: min(0.45, max(s * 1.4, 0.16)),
                           brightness: min(max(br, 0.74), 0.95),
                           alpha: 1).usingColorSpace(.sRGB)
        out.append(RGB(r: Double(airy?.redComponent ?? 0.85),
                       g: Double(airy?.greenComponent ?? 0.85),
                       b: Double(airy?.blueComponent ?? 0.88)))
    }
    return out
}

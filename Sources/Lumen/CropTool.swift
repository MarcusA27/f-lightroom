import SwiftUI
import AppKit

// Aspect presets for the crop tool. `ratio` is the desired output width/height;
// nil means unconstrained. `.original` matches the image's own shape.
enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free"
    case original = "Original"
    case square = "1:1"
    case portrait = "4:5"
    case wide = "16:9"

    var id: String { rawValue }

    func ratio(imageAspect: CGFloat) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return imageAspect
        case .square: return 1
        case .portrait: return 4.0 / 5.0
        case .wide: return 16.0 / 9.0
        }
    }
}

let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

// Crop an image to a normalized rect (top-left origin, y-down). Full rect is a
// no-op. Returns a fresh NSImage sized to the cropped pixels.
func cropped(_ image: NSImage, to rect: CGRect) -> NSImage {
    guard rect != fullCrop,
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    let px = CGRect(x: rect.minX * w, y: rect.minY * h,
                    width: rect.width * w, height: rect.height * h).integral
    guard px.width >= 1, px.height >= 1, let sub = cg.cropping(to: px) else { return image }
    return NSImage(cgImage: sub, size: NSSize(width: sub.width, height: sub.height))
}

// The largest rect of the given output aspect, centered in the whole image.
func maximalCrop(outputRatio r: CGFloat, imageAspect: CGFloat) -> CGRect {
    // In normalized coords, output ratio R = (w·imgAspect)/(h) → h/w = imageAspect/R.
    let ratioN = imageAspect / r
    var w = 1.0, h = w * ratioN
    if h > 1 { h = 1; w = h / ratioN }
    return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
}

// Fit a w/h aspect into a rect, centered — the on-screen frame of the image.
func aspectFitRect(_ ar: CGFloat, in r: CGRect) -> CGRect {
    var w = r.width, h = r.height
    if ar > r.width / r.height { h = w / ar } else { w = h * ar }
    return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
}

// Interactive crop rectangle over the photo: dimmed exterior, thirds grid, and
// eight drag handles. Reports the live normalized crop through the binding.
struct CropOverlay: View {
    let imageAspect: CGFloat        // w/h of the uncropped (rotated) image
    let aspect: CropAspect
    @Binding var crop: CGRect       // normalized, top-left origin

    private enum Handle { case tl, tr, bl, br, t, b, l, r, move }
    @State private var active: Handle?
    @State private var startCrop = fullCrop
    @State private var startN = CGPoint.zero
    // Which edges [l, t, r, b] were pinned to the image boundary last event, so a
    // haptic fires only when an edge newly reaches a rail.
    @State private var prevRails = [false, false, false, false]

    private let inset: CGFloat = 12
    private let minSize: CGFloat = 0.05

    var body: some View {
        GeometryReader { geo in
            let fit = aspectFitRect(imageAspect,
                                    in: CGRect(origin: .zero, size: geo.size).insetBy(dx: inset, dy: inset))
            ZStack {
                Canvas { ctx, _ in draw(ctx, fit: fit) }
                CropTracker(
                    onDown: { p in begin(at: p, fit: fit) },
                    onDrag: { p in drag(to: p, fit: fit) },
                    onUp: { active = nil }
                )
            }
        }
    }

    // MARK: Drawing

    private func screenRect(_ c: CGRect, _ fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + c.minX * fit.width, y: fit.minY + c.minY * fit.height,
               width: c.width * fit.width, height: c.height * fit.height)
    }

    private func draw(_ ctx: GraphicsContext, fit: CGRect) {
        let cr = screenRect(crop, fit)

        // Dim everything inside the image frame except the crop.
        var mask = Path(fit)
        mask.addRect(cr)
        ctx.fill(mask, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))

        // Thirds grid.
        var grid = Path()
        for i in 1...2 {
            let x = cr.minX + cr.width * CGFloat(i) / 3
            let y = cr.minY + cr.height * CGFloat(i) / 3
            grid.move(to: CGPoint(x: x, y: cr.minY)); grid.addLine(to: CGPoint(x: x, y: cr.maxY))
            grid.move(to: CGPoint(x: cr.minX, y: y)); grid.addLine(to: CGPoint(x: cr.maxX, y: y))
        }
        ctx.stroke(grid, with: .color(.white.opacity(0.35)), lineWidth: 0.5)

        // Border.
        ctx.stroke(Path(cr), with: .color(.white.opacity(0.9)), lineWidth: 1)

        // Handles: L-brackets at the corners, short ticks at the edge midpoints.
        let arm: CGFloat = 18, tick: CGFloat = 22
        var handles = Path()
        for (h, p) in handlePoints(cr) {
            switch h {
            case .tl:
                handles.move(to: CGPoint(x: p.x, y: p.y + arm)); handles.addLine(to: p)
                handles.addLine(to: CGPoint(x: p.x + arm, y: p.y))
            case .tr:
                handles.move(to: CGPoint(x: p.x - arm, y: p.y)); handles.addLine(to: p)
                handles.addLine(to: CGPoint(x: p.x, y: p.y + arm))
            case .bl:
                handles.move(to: CGPoint(x: p.x, y: p.y - arm)); handles.addLine(to: p)
                handles.addLine(to: CGPoint(x: p.x + arm, y: p.y))
            case .br:
                handles.move(to: CGPoint(x: p.x - arm, y: p.y)); handles.addLine(to: p)
                handles.addLine(to: CGPoint(x: p.x, y: p.y - arm))
            case .t, .b:
                handles.move(to: CGPoint(x: p.x - tick / 2, y: p.y))
                handles.addLine(to: CGPoint(x: p.x + tick / 2, y: p.y))
            case .l, .r:
                handles.move(to: CGPoint(x: p.x, y: p.y - tick / 2))
                handles.addLine(to: CGPoint(x: p.x, y: p.y + tick / 2))
            case .move: break
            }
        }
        // Dark underlay for contrast on bright images, then the white brackets.
        ctx.stroke(handles, with: .color(.black.opacity(0.3)),
                   style: StrokeStyle(lineWidth: 4.5, lineCap: .butt, lineJoin: .miter))
        ctx.stroke(handles, with: .color(.white),
                   style: StrokeStyle(lineWidth: 3, lineCap: .butt, lineJoin: .miter))
    }

    private func handlePoints(_ cr: CGRect) -> [(Handle, CGPoint)] {
        [(.tl, CGPoint(x: cr.minX, y: cr.minY)), (.tr, CGPoint(x: cr.maxX, y: cr.minY)),
         (.bl, CGPoint(x: cr.minX, y: cr.maxY)), (.br, CGPoint(x: cr.maxX, y: cr.maxY)),
         (.t, CGPoint(x: cr.midX, y: cr.minY)), (.b, CGPoint(x: cr.midX, y: cr.maxY)),
         (.l, CGPoint(x: cr.minX, y: cr.midY)), (.r, CGPoint(x: cr.maxX, y: cr.midY))]
    }

    // MARK: Interaction

    private func normalized(_ p: CGPoint, _ fit: CGRect) -> CGPoint {
        CGPoint(x: (p.x - fit.minX) / fit.width, y: (p.y - fit.minY) / fit.height)
    }

    private func begin(at p: CGPoint, fit: CGRect) {
        let cr = screenRect(crop, fit)
        let threshold: CGFloat = 22
        active = handlePoints(cr).first { hypot($0.1.x - p.x, $0.1.y - p.y) < threshold }?.0
            ?? (cr.insetBy(dx: -2, dy: -2).contains(p) ? .move : nil)
        startCrop = crop
        startN = normalized(p, fit)
        prevRails = rails(of: crop)   // seed so we don't tick on an already-pinned edge
    }

    private func drag(to p: CGPoint, fit: CGRect) {
        guard let h = active else { return }
        let pN = normalized(p, fit)
        let d = CGPoint(x: pN.x - startN.x, y: pN.y - startN.y)

        if h == .move {
            let nx = min(max(0, startCrop.minX + d.x), 1 - startCrop.width)
            let ny = min(max(0, startCrop.minY + d.y), 1 - startCrop.height)
            commit(CGRect(x: nx, y: ny, width: startCrop.width, height: startCrop.height))
            return
        }

        var l = startCrop.minX, t = startCrop.minY, r = startCrop.maxX, b = startCrop.maxY
        switch h {
        case .tl: l += d.x; t += d.y
        case .tr: r += d.x; t += d.y
        case .bl: l += d.x; b += d.y
        case .br: r += d.x; b += d.y
        case .t:  t += d.y
        case .b:  b += d.y
        case .l:  l += d.x
        case .r:  r += d.x
        case .move: break
        }
        l = max(0, min(l, 1)); r = max(0, min(r, 1))
        t = max(0, min(t, 1)); b = max(0, min(b, 1))
        if r - l < minSize { if h == .tl || h == .bl || h == .l { l = r - minSize } else { r = l + minSize } }
        if b - t < minSize { if h == .tl || h == .tr || h == .t { t = b - minSize } else { b = t + minSize } }
        var rect = CGRect(x: l, y: t, width: r - l, height: b - t)

        if let ratio = aspect.ratio(imageAspect: imageAspect) {
            rect = constrain(rect, handle: h, outputRatio: ratio)
        }
        commit(rect)
    }

    // Which edges [l, t, r, b] are pinned to the image boundary.
    private func rails(of rect: CGRect) -> [Bool] {
        let eps: CGFloat = 0.002
        return [rect.minX <= eps, rect.minY <= eps, rect.maxX >= 1 - eps, rect.maxY >= 1 - eps]
    }

    // Publish the crop and tick once for each edge that just reached a rail.
    private func commit(_ rect: CGRect) {
        let now = rails(of: rect)
        if zip(now, prevRails).contains(where: { $0 && !$1 }) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        prevRails = now
        crop = rect
    }

    // Keep the output aspect while resizing, anchored at the fixed corner/edge.
    private func constrain(_ rect: CGRect, handle: Handle, outputRatio ratio: CGFloat) -> CGRect {
        let ratioN = imageAspect / ratio          // normalized height / width
        var w = rect.width
        var h = w * ratioN
        // Anchor point stays fixed; the dragged corner/edge moves.
        let anchorRight = handle == .tl || handle == .bl || handle == .l
        let anchorBottom = handle == .tl || handle == .tr || handle == .t
        // For vertical-only handles drive width from height instead.
        if handle == .t || handle == .b { h = rect.height; w = h / ratioN }

        var l = anchorRight ? rect.maxX - w : rect.minX
        var t = anchorBottom ? rect.maxY - h : rect.minY
        // Clamp within bounds, nudging the anchor if we hit an edge.
        if l < 0 { l = 0 }
        if t < 0 { t = 0 }
        if l + w > 1 { w = 1 - l; h = w * ratioN }
        if t + h > 1 { h = 1 - t; w = h / ratioN; if anchorRight { l = rect.maxX - w } }
        return CGRect(x: l, y: t, width: w, height: h)
    }
}

// Identifies a crop control for hit-testing by the mouse monitor.
enum CropControl: Hashable {
    case aspect(CropAspect)
    case cancel
    case apply
}

// A local mouse-down monitor — the only thing that reliably works in the title
// bar, whose top region swallows normal view clicks. Converts the click to
// SwiftUI-global coordinates and hands it to `onClick`; returning true consumes
// it. Mirrors how KeyCatcher handles keys.
struct MouseCatcher: NSViewRepresentable {
    var enabled: Bool
    var onClick: (CGPoint) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView {
        context.coordinator.parent = self; context.coordinator.sync(); return NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self; context.coordinator.sync()
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator {
        var parent: MouseCatcher
        private var monitor: Any?
        init(_ parent: MouseCatcher) { self.parent = parent }

        func sync() { parent.enabled ? start() : stop() }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                let loc = event.locationInWindow
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self,
                          let content = NSApp.windows.first(where: { !($0 is NSPanel) })?.contentView
                    else { return false }
                    // AppKit window coords are bottom-left; SwiftUI global is top-left.
                    let p = CGPoint(x: loc.x, y: content.bounds.height - loc.y)
                    return self.parent.onClick(p)
                }
                return handled ? nil : event
            }
        }

        func stop() { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
    }
}

// Press/drag tracker for the crop overlay. Top-left origin, blocks window drag.
struct CropTracker: NSViewRepresentable {
    var onDown: (CGPoint) -> Void
    var onDrag: (CGPoint) -> Void
    var onUp: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = TrackView(); v.configure(onDown, onDrag, onUp); return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackView)?.configure(onDown, onDrag, onUp)
    }

    final class TrackView: NSView {
        private var onDown: ((CGPoint) -> Void)?
        private var onDrag: ((CGPoint) -> Void)?
        private var onUp: (() -> Void)?

        func configure(_ d: @escaping (CGPoint) -> Void, _ m: @escaping (CGPoint) -> Void, _ u: @escaping () -> Void) {
            onDown = d; onDrag = m; onUp = u
        }

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        private func loc(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
        override func mouseDown(with event: NSEvent)    { onDown?(loc(event)) }
        override func mouseDragged(with event: NSEvent) { onDrag?(loc(event)) }
        override func mouseUp(with event: NSEvent)      { onUp?() }
    }
}

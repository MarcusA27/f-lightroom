import SwiftUI
import CoreImage

extension Notification.Name {
    static let rotateRight = Notification.Name("rotateRight")
    static let chooseFolder = Notification.Name("chooseFolder")
    static let exportPhoto = Notification.Name("exportPhoto")
}

struct ContentView: View {
    @StateObject private var library = PhotoLibrary()
    @State private var selectedIndex = 0
    @State private var currentImage: NSImage?
    @State private var baseImage: NSImage?
    @State private var rotations: [URL: Int] = [:]
    @State private var currentTint: Color = .clear
    @State private var histogram: Histogram?
    @State private var adj = Adjustments()
    @State private var editsByURL: [URL: Adjustments] = [:]
    @State private var previewBase: NSImage?
    @State private var ambientImage: NSImage?
    @State private var editTask: Task<Void, Never>?
    @State private var toast: String?
    @State private var didFixLaunchGlass = false

    private var current: Photo? {
        library.photos.indices.contains(selectedIndex) ? library.photos[selectedIndex] : nil
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                titleBar
                Group {
                    if library.photos.isEmpty {
                        emptyState
                    } else {
                        photoContent
                    }
                }
            }

            Color.clear
                .frame(width: 12)
                .frame(maxHeight: .infinity)
                .pureGlass()

            sidePanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KeyCatcher(
            onLeft: { step(-1) },
            onRight: { step(1) },
            onFullScreen: toggleFullScreen,
            onRotate: { rotate(by: 1) }
        ))
        .onAppear {
            // Let the empty state render first so the Liquid Glass surfaces
            // establish behind-window blending over the settled transparent
            // window. Restoring the folder synchronously here makes the glass
            // latch onto an opaque blending mode during the cold launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                library.restoreLastFolder()
            }
        }
        .onChange(of: library.photos) { _, _ in
            loadCatalog()
            selectedIndex = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .rotateRight)) { _ in
            rotate(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chooseFolder)) { _ in
            library.chooseFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportPhoto)) { _ in
            exportCurrent()
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .pureGlass(cornerRadius: 10)
                    .padding(.bottom, 116)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 8)

            if library.isLoading {
                ProgressView().controlSize(.small)
            } else if !library.photos.isEmpty {
                Text("\(selectedIndex + 1) / \(library.photos.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .liquidGlass(cornerRadius: 0, tint: currentTint)
    }

    // MARK: - Side panel (editing controls, coming soon)

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HistogramView(histogram: histogram)
                .frame(height: 100)

            adjustmentsSection

            Spacer()

            Button { revertAll() } label: {
                Label("Revert", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(adj.isIdentity)
        }
        .padding(12)
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        // Depth lives in the background so it doesn't wash over the controls.
        .background {
            ZStack {
                Rectangle().fill(.ultraThickMaterial)
                LinearGradient(
                    colors: [.white.opacity(0.10), .clear, .black.opacity(0.06)],
                    startPoint: .top, endPoint: .bottom
                )
                GrainOverlay().opacity(0.35)
            }
        }
    }

    private var adjustmentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            scrubRow("thermometer.medium", $adj.temperature,
                     neg: Color(red: 0.28, green: 0.56, blue: 1.0),
                     pos: Color(red: 1.0, green: 0.72, blue: 0.28))
            scrubRow("drop.halffull", $adj.tint,
                     neg: Color(red: 0.32, green: 0.8, blue: 0.4),
                     pos: Color(red: 0.85, green: 0.35, blue: 0.82))

            Divider().padding(.vertical, 2)

            scrubRow("plusminus.circle", $adj.exposure, neg: fillTint, pos: fillTint,
                     format: { $0 == 0 ? "0" : String(format: "%+.2f", $0 * 0.02) })
            scrubRow("circle.lefthalf.filled", $adj.contrast, neg: fillTint, pos: fillTint)
            scrubRow("sun.max", $adj.highlights, neg: fillTint, pos: fillTint)
            scrubRow("moon", $adj.shadows, neg: fillTint, pos: fillTint)
            scrubRow("camera.filters", $adj.saturation, neg: fillTint, pos: fillTint)
        }
    }

    // The neutral adjustments glow with the photo's own color so the panel
    // speaks the same tinted-glass language as the rest of the app.
    private var fillTint: Color {
        currentTint == .clear ? Color(white: 0.7) : currentTint
    }

    private func scrubRow(
        _ icon: String,
        _ value: Binding<Double>,
        neg: Color, pos: Color,
        format: @escaping (Double) -> String = ScrubRow.intFormat
    ) -> some View {
        ScrubRow(icon: icon, value: value, negColor: neg, posColor: pos, format: format) { editing in
            updatePreview(live: editing)
        }
    }

    private func revertAll() {
        adj = Adjustments()
        updatePreview(live: false)
    }

    // MARK: - Main photo

    private var photoContent: some View {
        VStack(spacing: 0) {
            // Photo area: opaque (black + ambient blur), so the desktop only
            // shows through the filmstrip below — not the letterbox.
            ZStack {
                if let currentImage {
                    Image(nsImage: currentImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                        .transition(.opacity)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    Color.black
                    if let ambientImage {
                        Image(nsImage: ambientImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .scaleEffect(1.3)
                            .blur(radius: 60)
                            .overlay(Color.black.opacity(0.25))
                    }
                }
            }
            .clipped()

            // Filmstrip sits over the clear (non-opaque) window, so its glass
            // refracts the desktop wallpaper behind the window.
            filmstrip
        }
        .animation(.easeInOut(duration: 0.25), value: current?.id)
        .animation(.easeInOut(duration: 0.25), value: currentTint)
        .task(id: current?.url) {
            currentImage = nil
            baseImage = nil
            previewBase = nil
            ambientImage = nil
            histogram = nil
            guard let url = current?.url else { adj = Adjustments(); return }
            // Restore this photo's saved edit (non-destructive: a recipe, not pixels).
            let a = editsByURL[url] ?? Adjustments()
            adj = a
            let turns = rotations[url] ?? 0
            let result = await Task.detached(priority: .userInitiated) { () -> (NSImage, RGB?, Histogram?, NSImage, NSImage)? in
                guard let img = NSImage(contentsOf: url) else { return nil }
                let proxy = downscaled(img, maxDim: 1400)
                let edited = a.isIdentity ? img : (applyAdjustments(img, a) ?? img)
                let display = turns == 0 ? edited : rotatedImage(edited, quarterTurns: turns)
                return (img, averageColor(of: img), computeHistogram(img), proxy, display)
            }.value
            guard !Task.isCancelled, let result else { return }
            baseImage = result.0
            previewBase = result.3
            histogram = result.2
            currentImage = result.4
            ambientImage = result.4
            if let rgb = result.1 {
                currentTint = Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
            }
            // The very first photo at cold launch renders the Liquid Glass
            // surfaces in opaque (within-window) blending. Re-key the window
            // once — the same cycle ⌘O triggers — to force behind-window glass.
            if !didFixLaunchGlass {
                didFixLaunchGlass = true
                // Run after the opaque photo frame has actually painted (which
                // is what latches the glass), then force a real hide/show cycle
                // to re-establish behind-window blending — same as ⌘O does.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    reestablishGlass()
                }
            }
        }
    }

    // Order the window out and back in — a true key resign/become cycle that
    // forces the Liquid Glass views to re-evaluate to translucent blending.
    private func reestablishGlass() {
        guard let w = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
        w.isOpaque = false
        w.backgroundColor = .clear
        w.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func rotate(by delta: Int) {
        guard let url = current?.url else { return }
        rotations[url] = (((rotations[url] ?? 0) + delta) % 4 + 4) % 4
        updatePreview(live: false)
    }

    // Rebuild the displayed image from the base: white balance, then rotation.
    // `live` uses the downscaled proxy for smooth dragging; the full-res render
    // happens on release. The latest render wins (older ones are discarded).
    private func updatePreview(live: Bool) {
        guard let url = current?.url else { return }
        guard let base = (live ? (previewBase ?? baseImage) : baseImage) else { return }
        let a = adj
        // Persist this photo's edit recipe so switching photos never loses it.
        editsByURL[url] = a.isIdentity ? nil : a
        // Commit to disk on release / rotate / revert (not during a live drag).
        if !live { persistCatalog() }
        let turns = rotations[url] ?? 0
        editTask?.cancel()
        editTask = Task { @MainActor in
            let img = await Task.detached(priority: .userInitiated) { () -> NSImage in
                let edited = a.isIdentity ? base : (applyAdjustments(base, a) ?? base)
                return turns == 0 ? edited : rotatedImage(edited, quarterTurns: turns)
            }.value
            guard !Task.isCancelled, current?.url == url else { return }
            currentImage = img
            if !live { ambientImage = img }
        }
    }

    // MARK: - Filmstrip

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(library.photos.enumerated()), id: \.element.id) { index, photo in
                        ThumbnailView(url: photo.url, maxPixel: 160)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(.white, lineWidth: 1.5)
                                    .shadow(color: .white.opacity(0.5), radius: 2)
                                    .shadow(color: .white.opacity(0.3), radius: 4)
                                    .opacity(index == selectedIndex ? 1 : 0)
                                    .allowsHitTesting(false)
                            }
                            .overlay(alignment: .topTrailing) {
                                if isEdited(photo.url) {
                                    Circle()
                                        .fill(.white)
                                        .frame(width: 5, height: 5)
                                        .shadow(color: .black.opacity(0.5), radius: 1)
                                        .padding(5)
                                        .allowsHitTesting(false)
                                }
                            }
                            .id(index)
                            .onTapGesture { selectedIndex = index }
                    }
                }
                .padding(8)
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 48)
                    Rectangle().fill(.black)
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 48)
                }
            }
            .frame(height: 96)
            .liquidGlass(cornerRadius: 0, tint: currentTint)
            .onChange(of: selectedIndex) { _, new in
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        EmptyStateView(
            recents: library.recentFolders,
            onOpen: { library.load(folder: $0) },
            onChoose: { library.chooseFolder() }
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let dir = urls.first(where: {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }) else { return false }
            library.load(folder: dir)
            return true
        }
    }

    // MARK: - Actions

    private func isEdited(_ url: URL) -> Bool {
        editsByURL[url] != nil || (rotations[url] ?? 0) != 0
    }

    // Apply the recipe at full resolution and write a JPEG copy next to the
    // original. Never overwrites the original.
    private func exportCurrent() {
        guard let url = current?.url, let base = baseImage else { return }
        let a = adj
        let turns = rotations[url] ?? 0
        Task { @MainActor in
            let dest = await Task.detached(priority: .userInitiated) {
                exportEdited(base: base, adjustments: a, turns: turns, originalURL: url)
            }.value
            showToast(dest.map { "Saved \($0.lastPathComponent)" } ?? "Couldn’t save copy")
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeIn(duration: 0.3)) { toast = nil }
        }
    }

    // MARK: - Edit catalog (persisted per folder)

    private static let catalogName = ".lumen.json"

    private var folderURL: URL? {
        library.photos.first?.url.deletingLastPathComponent()
    }

    // Replace the in-memory edits with whatever this folder's catalog holds.
    private func loadCatalog() {
        guard let folder = folderURL else { editsByURL = [:]; rotations = [:]; return }
        var edits: [URL: Adjustments] = [:]
        var rots: [URL: Int] = [:]
        let url = folder.appendingPathComponent(Self.catalogName)
        if let data = try? Data(contentsOf: url),
           let catalog = try? JSONDecoder().decode([String: PhotoEditRecord].self, from: data) {
            for (name, rec) in catalog {
                let fileURL = folder.appendingPathComponent(name)
                if !rec.adjustments.isIdentity { edits[fileURL] = rec.adjustments }
                if rec.rotation != 0 { rots[fileURL] = rec.rotation }
            }
        }
        editsByURL = edits
        rotations = rots
    }

    // Rewrite the folder's catalog from current state; delete it when nothing's edited.
    private func persistCatalog() {
        guard let folder = folderURL else { return }
        var catalog: [String: PhotoEditRecord] = [:]
        for photo in library.photos {
            var rec = PhotoEditRecord()
            var edited = false
            if let a = editsByURL[photo.url], !a.isIdentity { rec.adjustments = a; edited = true }
            if let r = rotations[photo.url], r != 0 { rec.rotation = r; edited = true }
            if edited { catalog[photo.url.lastPathComponent] = rec }
        }
        let fileURL = folder.appendingPathComponent(Self.catalogName)
        let snapshot = catalog
        Task.detached(priority: .utility) {
            if snapshot.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func step(_ delta: Int) {
        let next = selectedIndex + delta
        if library.photos.indices.contains(next) { selectedIndex = next }
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}

private extension View {
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self
                .background((tint ?? .clear).opacity(0.3))
                .glassEffect(.clear.tint(tint), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    // Neutral, untinted Liquid Glass — the standard macOS HUD material.
    @ViewBuilder
    func pureGlass(cornerRadius: CGFloat = 0) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

func rotatedImage(_ image: NSImage, quarterTurns turns: Int) -> NSImage {
    let t = ((turns % 4) + 4) % 4
    guard t != 0,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let cg = rep.cgImage,
          let rotated = rotateCGImage(cg, quarterTurns: t) else { return image }
    return NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
}

private func rotateCGImage(_ cg: CGImage, quarterTurns turns: Int) -> CGImage? {
    let w = cg.width, h = cg.height
    let radians: CGFloat
    let newW: Int, newH: Int
    switch turns {
    case 1:  radians = -.pi / 2; newW = h; newH = w   // 90° clockwise
    case 2:  radians = .pi;      newW = w; newH = h   // 180°
    case 3:  radians = .pi / 2;  newW = h; newH = w   // 90° counter-clockwise
    default: return cg
    }

    // Always render into device RGB — the source's own color space (grayscale,
    // CMYK, opaque-no-alpha) often can't back a premultipliedLast context.
    guard let ctx = CGContext(
        data: nil, width: newW, height: newH,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.translateBy(x: CGFloat(newW) / 2, y: CGFloat(newH) / 2)
    ctx.rotate(by: radians)
    ctx.draw(cg, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2,
                            width: CGFloat(w), height: CGFloat(h)))
    return ctx.makeImage()
}

struct RGB: Sendable {
    let r, g, b: Double
}

struct Histogram: Sendable {
    let r: [Int]
    let g: [Int]
    let b: [Int]
}

let sharedCIContext = CIContext()

// A smaller copy used for smooth live editing while a slider is being dragged.
func downscaled(_ image: NSImage, maxDim: CGFloat) -> NSImage {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let cg = rep.cgImage else { return image }
    let w = cg.width, h = cg.height
    let scale = min(1, maxDim / CGFloat(max(w, h)))
    guard scale < 1 else { return image }
    let nw = max(1, Int(CGFloat(w) * scale)), nh = max(1, Int(CGFloat(h) * scale))
    guard let ctx = CGContext(
        data: nil, width: nw, height: nh,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return image }
    ctx.interpolationQuality = .medium
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
    guard let out = ctx.makeImage() else { return image }
    return NSImage(cgImage: out, size: NSSize(width: nw, height: nh))
}

// One photo's persisted edit: the adjustment recipe plus quarter-turn rotation.
struct PhotoEditRecord: Codable, Sendable {
    var adjustments = Adjustments()
    var rotation = 0
}

// All slider values are -100...100 with 0 = no change.
struct Adjustments: Equatable, Sendable, Codable {
    var temperature = 0.0
    var tint = 0.0
    var exposure = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var saturation = 0.0

    var isIdentity: Bool { self == Adjustments() }
}

func applyAdjustments(_ image: NSImage, _ a: Adjustments) -> NSImage? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let cg = rep.cgImage else { return nil }
    var ci = CIImage(cgImage: cg)
    let extent = ci.extent

    func apply(_ name: String, _ params: [String: Any]) {
        guard let f = CIFilter(name: name) else { return }
        f.setValue(ci, forKey: kCIInputImageKey)
        for (k, v) in params { f.setValue(v, forKey: k) }
        ci = f.outputImage ?? ci
    }

    if a.temperature != 0 || a.tint != 0 {
        apply("CITemperatureAndTint", [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: 6500 - a.temperature * 30, y: -a.tint * 1.5)
        ])
    }
    if a.exposure != 0 {
        apply("CIExposureAdjust", [kCIInputEVKey: a.exposure * 0.02])
    }
    if a.highlights != 0 || a.shadows != 0 {
        apply("CIToneCurve", [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 0.25, y: 0.25 + a.shadows / 100 * 0.2),
            "inputPoint2": CIVector(x: 0.5, y: 0.5),
            "inputPoint3": CIVector(x: 0.75, y: 0.75 + a.highlights / 100 * 0.2),
            "inputPoint4": CIVector(x: 1, y: 1)
        ])
    }
    if a.contrast != 0 || a.saturation != 0 {
        apply("CIColorControls", [
            kCIInputContrastKey: 1 + a.contrast / 100 * 0.4,
            kCIInputSaturationKey: 1 + a.saturation / 100
        ])
    }

    guard let outCG = sharedCIContext.createCGImage(ci, from: extent) else { return nil }
    return NSImage(cgImage: outCG, size: NSSize(width: outCG.width, height: outCG.height))
}

// Renders the edited full-res image and writes it as a JPEG copy alongside the
// original (e.g. "beach.jpg" -> "beach-edited.jpg"). Returns the written URL.
func exportEdited(base: NSImage, adjustments a: Adjustments, turns: Int, originalURL: URL) -> URL? {
    let edited = a.isIdentity ? base : (applyAdjustments(base, a) ?? base)
    let final = turns == 0 ? edited : rotatedImage(edited, quarterTurns: turns)
    guard let tiff = final.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
    else { return nil }

    let folder = originalURL.deletingLastPathComponent()
    let stem = originalURL.deletingPathExtension().lastPathComponent
    var dest = folder.appendingPathComponent("\(stem)-edited.jpg")
    var n = 2
    while FileManager.default.fileExists(atPath: dest.path) {
        dest = folder.appendingPathComponent("\(stem)-edited-\(n).jpg")
        n += 1
    }
    do { try data.write(to: dest); return dest } catch { return nil }
}

func computeHistogram(_ image: NSImage, bins: Int = 256) -> Histogram? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let cg = rep.cgImage else { return nil }

    // Downsample for speed — the distribution barely changes.
    let w = min(cg.width, 400)
    let h = max(1, Int(Double(w) * Double(cg.height) / Double(max(cg.width, 1))))
    var data = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
        data: &data, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

    var r = [Int](repeating: 0, count: bins)
    var g = [Int](repeating: 0, count: bins)
    var b = [Int](repeating: 0, count: bins)
    let scale = bins - 1
    var i = 0
    while i < data.count {
        r[Int(data[i]) * scale / 255] += 1
        g[Int(data[i + 1]) * scale / 255] += 1
        b[Int(data[i + 2]) * scale / 255] += 1
        i += 4
    }
    return Histogram(r: r, g: g, b: b)
}

// A label + value with no visible slider: drag anywhere across the row to
// scrub, a hairline track fills from center to show deviation, double-click resets.
struct ScrubRow: View {
    let icon: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var negColor: Color = Color(white: 0.7)
    var posColor: Color = Color(white: 0.7)
    var format: (Double) -> String = ScrubRow.intFormat
    var onEditingChanged: (Bool) -> Void

    static let intFormat: (Double) -> String = { v in
        v == 0 ? "0" : (v > 0 ? "+\(Int(v))" : "\(Int(v))")
    }

    var body: some View {
        let active = value != 0
        let fill = value >= 0 ? posColor : negColor

        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(active ? AnyShapeStyle(fill) : AnyShapeStyle(.secondary))
                .frame(width: 30, alignment: .leading)
                .offset(y: 4)

            Canvas { ctx, size in
                let w = size.width, h = size.height
                let span = range.upperBound - range.lowerBound
                let cx = CGFloat((0 - range.lowerBound) / span) * w
                let vx = CGFloat((value - range.lowerBound) / span) * w
                let baseY = h - 5.5
                let tickH: CGFloat = 11

                // Evenly spaced tick grid, centered in the width.
                let spacing: CGFloat = 7
                let count = max(2, Int(w / spacing))
                let margin = (w - CGFloat(count) * spacing) / 2
                for i in 0...count {
                    let tx = margin + CGFloat(i) * spacing
                    let inSpan = tx >= min(cx, vx) - 0.5 && tx <= max(cx, vx) + 0.5
                    let color = inSpan && active
                        ? fill.opacity(0.9)
                        : Color.primary.opacity(0.16)
                    var p = Path()
                    p.move(to: CGPoint(x: tx, y: baseY - tickH / 2))
                    p.addLine(to: CGPoint(x: tx, y: baseY + tickH / 2))
                    ctx.stroke(p, with: .color(color),
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                }

                // Neutral home dot above the zero mark.
                let dot = CGRect(x: cx - 2, y: 0, width: 4, height: 4)
                ctx.fill(Path(ellipseIn: dot), with: .color(.primary.opacity(0.3)))

                // Bold current-value indicator.
                var ind = Path()
                let indH: CGFloat = 17
                ind.move(to: CGPoint(x: vx, y: baseY - indH / 2))
                ind.addLine(to: CGPoint(x: vx, y: baseY + indH / 2))
                ctx.stroke(ind, with: .color(active ? fill : .primary.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .overlay {
                SliderInteraction(
                    onChange: { f in
                        value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                        onEditingChanged(true)
                    },
                    onEnded: { onEditingChanged(false) },
                    onReset: {
                        value = 0
                        onEditingChanged(false)
                    }
                )
            }

            Text(format(value))
                .font(.system(size: 11, weight: active ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(active ? AnyShapeStyle(fill) : AnyShapeStyle(.secondary))
                .frame(width: 30, alignment: .trailing)
                .offset(y: 4)
        }
    }
}

struct SliderInteraction: NSViewRepresentable {
    var onChange: (CGFloat) -> Void
    var onEnded: () -> Void
    var onReset: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let v = TrackView()
        v.configure(onChange, onEnded, onReset)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackView)?.configure(onChange, onEnded, onReset)
    }

    final class TrackView: NSView {
        private var onChange: ((CGFloat) -> Void)?
        private var onEnded: (() -> Void)?
        private var onReset: (() -> Void)?

        func configure(_ c: @escaping (CGFloat) -> Void, _ e: @escaping () -> Void, _ r: (() -> Void)?) {
            onChange = c; onEnded = e; onReset = r
        }

        override var mouseDownCanMoveWindow: Bool { false }

        private func report(_ event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            onChange?(max(0, min(1, p.x / max(1, bounds.width))))
        }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onReset?(); return }
            report(event)
        }
        override func mouseDragged(with event: NSEvent) { report(event) }
        override func mouseUp(with event: NSEvent) { onEnded?() }
    }
}

// Classic additive R/G/B histogram in a dark card.
struct HistogramView: View {
    let histogram: Histogram?

    var body: some View {
        Canvas { context, size in
            guard let h = histogram else { return }
            var ctx = context
            ctx.blendMode = .plusDarker
            let m = robustMax(h)
            ctx.fill(path(h.r, size, m), with: .color(.red.opacity(0.5)))
            ctx.fill(path(h.g, size, m), with: .color(.green.opacity(0.5)))
            ctx.fill(path(h.b, size, m), with: .color(.blue.opacity(0.5)))
        }
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // Ignore the pure black/white clip spikes so they don't flatten everything.
    private func robustMax(_ h: Histogram) -> CGFloat {
        func mid(_ a: [Int]) -> Int {
            a.count > 2 ? (a[1..<(a.count - 1)].max() ?? 1) : (a.max() ?? 1)
        }
        return CGFloat(max(mid(h.r), mid(h.g), mid(h.b), 1))
    }

    private func path(_ bins: [Int], _ size: CGSize, _ maxV: CGFloat) -> Path {
        var p = Path()
        let n = bins.count
        p.move(to: CGPoint(x: 0, y: size.height))
        for i in 0..<n {
            let x = size.width * CGFloat(i) / CGFloat(n - 1)
            let norm = min(1, CGFloat(bins[i]) / maxV)
            p.addLine(to: CGPoint(x: x, y: size.height * (1 - norm)))
        }
        p.addLine(to: CGPoint(x: size.width, y: size.height))
        p.closeSubpath()
        return p
    }
}

// A tiled monochrome-noise overlay for a film-grain texture.
struct GrainOverlay: View {
    static let image = makeGrain(140)

    var body: some View {
        Image(nsImage: Self.image)
            .resizable(resizingMode: .tile)
            .opacity(0.14)
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }
}

private func makeGrain(_ n: Int) -> NSImage {
    let count = n * n
    var px = [UInt8](repeating: 0, count: count * 4)
    for i in 0..<count {
        let v = UInt8.random(in: 30...225)
        px[i * 4] = v
        px[i * 4 + 1] = v
        px[i * 4 + 2] = v
        px[i * 4 + 3] = 255
    }
    let ctx = CGContext(
        data: &px, width: n, height: n,
        bitsPerComponent: 8, bytesPerRow: n * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: n, height: n))
}

func averageColor(of image: NSImage) -> RGB? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let cg = bitmap.cgImage else { return nil }

    let ci = CIImage(cgImage: cg)
    guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
        kCIInputImageKey: ci,
        kCIInputExtentKey: CIVector(cgRect: ci.extent)
    ]), let output = filter.outputImage else { return nil }

    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CIContext(options: [.workingColorSpace: NSNull()])
    context.render(
        output,
        toBitmap: &pixel,
        rowBytes: 4,
        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        format: .RGBA8,
        colorSpace: nil
    )

    // A whole-image average is usually a muddy gray, so boost saturation and
    // normalize brightness to get a tint that actually reads.
    let base = NSColor(srgbRed: CGFloat(pixel[0]) / 255,
                       green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255,
                       alpha: 1)
    guard let c = base.usingColorSpace(.sRGB) else {
        return RGB(r: Double(pixel[0]) / 255, g: Double(pixel[1]) / 255, b: Double(pixel[2]) / 255)
    }
    var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
    c.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
    let punchy = NSColor(hue: h,
                         saturation: min(1, max(s * 2.8, 0.6)),
                         brightness: min(max(br, 0.5), 0.85),
                         alpha: 1).usingColorSpace(.sRGB) ?? c

    return RGB(r: Double(punchy.redComponent),
               g: Double(punchy.greenComponent),
               b: Double(punchy.blueComponent))
}


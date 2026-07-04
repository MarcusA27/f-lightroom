import SwiftUI
import CoreImage

extension Notification.Name {
    static let rotateRight = Notification.Name("rotateRight")
    static let chooseFolder = Notification.Name("chooseFolder")
    static let exportPhoto = Notification.Name("exportPhoto")
    static let undoEdit = Notification.Name("undoEdit")
    static let redoEdit = Notification.Name("redoEdit")
    static let cropToggle = Notification.Name("cropToggle")
    static let describeVision = Notification.Name("describeVision")
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
    @State private var renderGen = RenderGen()
    // The unedited photo (rotation applied, no adjustments) shown while the
    // compare key is held, so you can flash back to the original.
    @State private var beforeImage: NSImage?
    @State private var comparing = false
    // Per-photo edit timeline: committed states with a moving pointer. ⌘Z/⌘⇧Z
    // walk it; a new edit after undoing truncates the redo branch.
    @State private var history: [EditState] = []
    @State private var historyIndex = 0
    // Non-destructive crop: a normalized rect (top-left origin) kept per photo.
    @State private var crops: [URL: CGRect] = [:]
    @State private var cropping = false
    @State private var cropDraft = fullCrop
    @State private var cropAspect: CropAspect = .free
    // Title-bar control frames (SwiftUI-global coords) for the mouse monitor.
    @State private var cropFrames: [CropControl: CGRect] = [:]
    @State private var toast: String?
    @State private var didFixLaunchGlass = false
    // "Describe your vision" — text → Claude → slider recipe.
    @State private var visionLoading = false
    // While a range-targeted slider (shadows/highlights) is dragged, its affected
    // pixels glow on the photo so you can see exactly what the slider reaches.
    @State private var activeMask: MaskKind?
    @State private var maskImage: NSImage?
    // The glow reveals only while Shift is held and the cursor is over a
    // range-targeted slider (shadows/highlights).
    @State private var shiftDown = false
    @State private var hoveredMask: MaskKind?

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
            onRotate: { rotate(by: 1) },
            onCompareDown: { if beforeImage != nil { comparing = true } },
            onCompareUp: { comparing = false },
            onEscape: { if cropping { cancelCrop() } },
            onShift: { down in shiftDown = down; refreshMask() }
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
        // While cropping, stop the title bar from being a window-drag region so
        // its buttons receive taps; restore dragging when crop mode exits.
        .background(MouseCatcher(enabled: cropping) { handleCropClick($0) })
        .onReceive(NotificationCenter.default.publisher(for: .rotateRight)) { _ in
            rotate(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chooseFolder)) { _ in
            library.chooseFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportPhoto)) { _ in
            exportCurrent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .undoEdit)) { _ in
            undo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .redoEdit)) { _ in
            redo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cropToggle)) { _ in
            toggleCrop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .describeVision)) { _ in
            promptVision()
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
            if cropping {
                cropTitleControls
            } else {
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
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .liquidGlass(cornerRadius: 0, tint: currentTint)
    }

    // Reports a control's global frame to the mouse monitor's hit-test table.
    private func cropFrame(_ ctrl: CropControl) -> some View {
        GeometryReader { g in
            Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in
                cropFrames[ctrl] = f
            }
        }
    }

    private func handleCropClick(_ p: CGPoint) -> Bool {
        guard cropping else { return false }
        for (ctrl, rect) in cropFrames where rect.contains(p) {
            switch ctrl {
            case .aspect(let a): setCropAspect(a)
            case .cancel: cancelCrop()
            case .apply: applyCrop()
            }
            return true
        }
        return false
    }

    // Crop controls live in the title bar. Clicks are delivered by MouseCatcher
    // (a local event monitor) hit-testing cropFrames — the title bar's top region
    // swallows normal view clicks, so nothing inside it receives taps directly.
    private var cropTitleControls: some View {
        HStack(spacing: 2) {
            Image(systemName: "xmark")
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background { cropFrame(.cancel) }
            Spacer()
            ForEach(CropAspect.allCases) { a in
                Text(a.rawValue)
                    .font(.system(size: 12, weight: cropAspect == a ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(cropAspect == a ? 1 : 0.55))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background { cropFrame(.aspect(a)) }
            }
            Spacer()
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background { cropFrame(.apply) }
        }
    }

    // MARK: - Side panel (editing controls, coming soon)

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HistogramView(histogram: histogram)
                .frame(height: 100)

            adjustmentsSection

            Spacer()

            HStack {
                Button { revertAll() } label: {
                    Label("Revert", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(adj.isIdentity)

                Spacer()

                compareControl
            }
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

    // Ask for the vision in a modal panel — its own key-capable window, so typing
    // works regardless of the borderless main window — then run it.
    private func promptVision() {
        guard currentImage != nil, !visionLoading else { return }
        let alert = NSAlert()
        alert.messageText = "Describe your vision"
        alert.informativeText = "What should this photo look like?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "e.g. warm golden-hour glow"
        alert.accessoryView = field
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let prompt = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty { runVision(prompt: prompt) }
        }
    }

    private func runVision(prompt: String) {
        guard !visionLoading, let img = currentImage else { return }
        visionLoading = true
        showToast("Reading your vision…")
        let cur = adj
        Task { @MainActor in
            defer { visionLoading = false }
            do {
                let (target, summary) = try await requestVisionEdit(image: img, prompt: prompt, current: cur)
                guard current?.url != nil else { return }
                withAnimation(.easeInOut(duration: 0.4)) { adj = target }
                // Route through the normal path so it renders, persists, and lands
                // on the undo timeline — ⌘Z reverts the whole AI edit.
                updatePreview(live: false)
                showToast(summary)
            } catch {
                showToast(visionErrorMessage(error))
            }
        }
    }

    private var adjustmentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            scrubRow("thermometer.medium", "Temperature", "Warm or cool the photo", $adj.temperature,
                     neg: Color(red: 0.28, green: 0.56, blue: 1.0),
                     pos: Color(red: 1.0, green: 0.72, blue: 0.28))
            scrubRow("drop.halffull", "Tint", "Green–magenta balance", $adj.tint,
                     neg: Color(red: 0.32, green: 0.8, blue: 0.4),
                     pos: Color(red: 0.85, green: 0.35, blue: 0.82))

            Divider().padding(.vertical, 2)

            scrubRow("plusminus.circle", "Exposure", "Overall brightness", $adj.exposure,
                     neg: fillTint, pos: fillTint,
                     format: { $0 == 0 ? "0" : String(format: "%+.2f", $0 * 0.02) })
            scrubRow("circle.lefthalf.filled", "Contrast", "Separation of lights and darks", $adj.contrast, neg: fillTint, pos: fillTint)
            scrubRow("sun.max", "Highlights", "The bright midtones", $adj.highlights, neg: fillTint, pos: fillTint, mask: .highlights)
            scrubRow("moon", "Shadows", "The dark midtones", $adj.shadows, neg: fillTint, pos: fillTint, mask: .shadows)
            scrubRow("sun.max.fill", "Whites", "The brightest point", $adj.whites, neg: fillTint, pos: fillTint, mask: .whites)
            scrubRow("moon.fill", "Blacks", "The darkest point", $adj.blacks, neg: fillTint, pos: fillTint, mask: .blacks)

            Divider().padding(.vertical, 2)

            scrubRow("sparkles", "Clarity", "Midtone punch and definition", $adj.clarity, neg: fillTint, pos: fillTint)
            scrubRow("paintpalette", "Vibrance", "Boosts muted colors, spares skin", $adj.vibrance, neg: fillTint, pos: fillTint)
            scrubRow("camera.filters", "Saturation", "Intensity of all colors", $adj.saturation, neg: fillTint, pos: fillTint)
        }
    }

    // The neutral adjustments glow with the photo's own color so the panel
    // speaks the same tinted-glass language as the rest of the app.
    private var fillTint: Color {
        currentTint == .clear ? Color(white: 0.7) : currentTint
    }

    private func scrubRow(
        _ icon: String,
        _ name: String,
        _ desc: String,
        _ value: Binding<Double>,
        neg: Color, pos: Color,
        format: @escaping (Double) -> String = ScrubRow.intFormat,
        mask: MaskKind? = nil
    ) -> some View {
        ScrubRow(icon: icon, name: name, desc: desc, value: value,
                 negColor: neg, posColor: pos, format: format,
                 onEditingChanged: { editing in updatePreview(live: editing) },
                 onHoverChanged: { hovering in
                     if hovering { hoveredMask = mask } else if hoveredMask == mask { hoveredMask = nil }
                     refreshMask()
                 })
    }

    // Show the glow only when both conditions hold: Shift is down and the cursor
    // is over a range-targeted slider. Called whenever either input changes.
    private func refreshMask() {
        if shiftDown, let kind = hoveredMask {
            if activeMask != kind { showMask(kind) }
        } else if activeMask != nil {
            hideMask()
        }
    }

    // Compute the affected-pixel glow off the current frame and fade it in. The
    // render is cheap on the proxy but async so grabbing the slider never hitches.
    private func showMask(_ kind: MaskKind) {
        guard let img = currentImage else { return }
        withAnimation(.easeInOut(duration: 0.2)) { activeMask = kind }
        Task { @MainActor in
            let m = await Task.detached(priority: .userInitiated) {
                affectedMask(img, kind: kind)
            }.value
            if activeMask == kind { maskImage = m }
        }
    }

    private func hideMask() {
        withAnimation(.easeInOut(duration: 0.25)) { activeMask = nil }
        maskImage = nil
    }

    // Hold to flash the original — mirrors the \ shortcut, and mirrors Revert
    // across the bottom bar so the panel stays symmetric.
    private var compareControl: some View {
        Label("Before", systemImage: "square.split.2x1")
            .font(.system(size: 11))
            .foregroundStyle(comparing ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if beforeImage != nil { comparing = true } }
                    .onEnded { _ in comparing = false }
            )
            .disabled(adj.isIdentity)
            .opacity(adj.isIdentity ? 0.4 : 1)
            .help("Hold to compare with the original (\\)")
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
                if let shown = (comparing ? beforeImage : nil) ?? currentImage {
                    Image(nsImage: shown)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                        .transition(.opacity)
                } else {
                    ProgressView().controlSize(.large)
                }

                // The glow lines up with the photo because it shares the same
                // pixel dimensions and layout (fit + 12pt inset).
                if let maskImage, activeMask != nil, !comparing {
                    Image(nsImage: maskImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                        // Add light to mark dark pixels; multiply (colorize/darken)
                        // to mark bright ones — additive red can't touch a highlight.
                        .blendMode(activeMask == .highlights || activeMask == .whites ? .multiply : .plusLighter)
                        .opacity(0.5)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if cropping, let img = currentImage {
                    CropOverlay(imageAspect: img.size.width / max(1, img.size.height),
                                aspect: cropAspect, crop: $cropDraft)
                }
            }
            .overlay(alignment: .top) {
                if comparing {
                    Text("BEFORE")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .tracking(1.5)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
                        .padding(.top, 20)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
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
        .animation(.easeInOut(duration: 0.12), value: comparing)
        .task(id: current?.url) {
            currentImage = nil
            baseImage = nil
            previewBase = nil
            ambientImage = nil
            beforeImage = nil
            comparing = false
            cropping = false
            histogram = nil
            guard let url = current?.url else { adj = Adjustments(); return }
            // Restore this photo's saved edit (non-destructive: a recipe, not pixels).
            let a = editsByURL[url] ?? Adjustments()
            adj = a
            let turns = rotations[url] ?? 0
            let cropRect = crops[url]
            // Seed the undo timeline with this photo's loaded state.
            history = [EditState(adj: a, rotation: turns, crop: cropRect)]
            historyIndex = 0
            let result = await Task.detached(priority: .userInitiated) { () -> (NSImage, RGB?, Histogram?, NSImage, NSImage, NSImage)? in
                guard let img = NSImage(contentsOf: url) else { return nil }
                let proxy = downscaled(img, maxDim: 1400)
                let edited = a.isIdentity ? img : (applyAdjustments(img, a) ?? img)
                let rotatedBefore = turns == 0 ? img : rotatedImage(img, quarterTurns: turns)
                let rotatedDisplay = turns == 0 ? edited : rotatedImage(edited, quarterTurns: turns)
                let before = cropRect.map { cropped(rotatedBefore, to: $0) } ?? rotatedBefore
                let display = cropRect.map { cropped(rotatedDisplay, to: $0) } ?? rotatedDisplay
                return (img, averageColor(of: img), computeHistogram(img), proxy, display, before)
            }.value
            guard !Task.isCancelled, let result else { return }
            baseImage = result.0
            previewBase = result.3
            histogram = result.2
            currentImage = result.4
            ambientImage = result.4
            beforeImage = result.5
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
        let turns = (((rotations[url] ?? 0) + delta) % 4 + 4) % 4
        rotations[url] = turns
        // Rotate any crop along with the image so it stays aligned (90° CW step).
        if var c = crops[url] {
            for _ in 0..<(((delta % 4) + 4) % 4) {
                c = CGRect(x: 1 - c.maxY, y: c.minX, width: c.height, height: c.width)
            }
            crops[url] = c
        }
        // Keep the before-compare image in the same orientation and crop.
        if let base = baseImage {
            let rot = turns == 0 ? base : rotatedImage(base, quarterTurns: turns)
            beforeImage = crops[url].map { cropped(rot, to: $0) } ?? rot
        }
        updatePreview(live: false)
    }

    // MARK: - Crop

    private var croppableAspect: CGFloat {
        guard let s = currentImage?.size, s.height > 0 else { return 1 }
        return s.width / s.height
    }

    // ⌘? / menu toggle: enter crop, or apply if already cropping.
    private func toggleCrop() {
        guard current?.url != nil else { return }
        if cropping { applyCrop() } else { beginCrop() }
    }

    private func beginCrop() {
        guard let url = current?.url else { return }
        cropDraft = crops[url] ?? fullCrop
        cropAspect = .free
        cropping = true
        // Re-render the full frame so the handles have room to work.
        updatePreview(live: false, record: false)
    }

    private func applyCrop() {
        guard let url = current?.url else { return }
        cropping = false
        crops[url] = cropDraft == fullCrop ? nil : cropDraft
        updatePreview(live: false)
    }

    private func cancelCrop() {
        cropping = false
        updatePreview(live: false, record: false)
    }

    private func setCropAspect(_ a: CropAspect) {
        cropAspect = a
        if let r = a.ratio(imageAspect: croppableAspect) {
            cropDraft = maximalCrop(outputRatio: r, imageAspect: croppableAspect)
        }
    }

    // MARK: - Undo / redo

    // Append a committed state, dropping any redo branch first.
    private func recordHistory(_ state: EditState) {
        guard history.indices.contains(historyIndex) else {
            history = [state]; historyIndex = 0; return
        }
        if history[historyIndex] == state { return }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(state)
        historyIndex = history.count - 1
    }

    private func undo() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        applyHistory()
    }

    private func redo() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        applyHistory()
    }

    // Replay the state at the current timeline pointer without recording it.
    private func applyHistory() {
        guard let url = current?.url, history.indices.contains(historyIndex) else { return }
        let s = history[historyIndex]
        adj = s.adj
        rotations[url] = s.rotation
        crops[url] = s.crop
        if let base = baseImage {
            let rot = s.rotation == 0 ? base : rotatedImage(base, quarterTurns: s.rotation)
            beforeImage = s.crop.map { cropped(rot, to: $0) } ?? rot
        }
        updatePreview(live: false, record: false)
    }

    // Rebuild the displayed image from the base: white balance, then rotation.
    // `live` uses the downscaled proxy for smooth dragging; the full-res render
    // happens on release. The latest render wins (older ones are discarded).
    private func updatePreview(live: Bool, record: Bool = true) {
        guard let url = current?.url else { return }
        guard let base = (live ? (previewBase ?? baseImage) : baseImage) else { return }
        let a = adj
        // Persist this photo's edit recipe so switching photos never loses it.
        editsByURL[url] = a.isIdentity ? nil : a
        let turns = rotations[url] ?? 0
        // While cropping we show the full frame so the handles have room; the
        // committed crop is baked in otherwise.
        let cropRect: CGRect? = cropping ? nil : crops[url]
        // Commit to disk and the undo timeline on release / rotate / revert
        // (not during a live drag, and not when replaying an undo/redo).
        if !live {
            persistCatalog()
            if record { recordHistory(EditState(adj: a, rotation: turns, crop: crops[url])) }
        }
        // Detached tasks don't inherit editTask's cancellation, so a fast drag
        // would otherwise render every intermediate value and back up a queue.
        // Bump a generation token and let stale live renders bail before (and
        // after) the expensive work, so only the latest one reaches the screen.
        let seq = renderGen
        let gen = seq.next()
        editTask?.cancel()
        editTask = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> (NSImage, Histogram?)? in
                if live && seq.current != gen { return nil }
                let edited = a.isIdentity ? base : (applyAdjustments(base, a) ?? base)
                let rotated = turns == 0 ? edited : rotatedImage(edited, quarterTurns: turns)
                let out = cropRect.map { cropped(rotated, to: $0) } ?? rotated
                if live && seq.current != gen { return nil }
                // Recompute the histogram off the edited pixels so it tracks the edit.
                return (out, computeHistogram(out))
            }.value
            guard !Task.isCancelled, current?.url == url, let result else { return }
            currentImage = result.0
            histogram = result.1
            if !live { ambientImage = result.0 }
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
        editsByURL[url] != nil || (rotations[url] ?? 0) != 0 || crops[url] != nil
    }

    // Apply the recipe at full resolution and write a JPEG copy next to the
    // original. Never overwrites the original.
    private func exportCurrent() {
        guard let url = current?.url, let base = baseImage else { return }
        let a = adj
        let turns = rotations[url] ?? 0
        let crop = crops[url]
        Task { @MainActor in
            let dest = await Task.detached(priority: .userInitiated) {
                exportEdited(base: base, adjustments: a, turns: turns, crop: crop, originalURL: url)
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
        guard let folder = folderURL else { editsByURL = [:]; rotations = [:]; crops = [:]; return }
        var edits: [URL: Adjustments] = [:]
        var rots: [URL: Int] = [:]
        var crps: [URL: CGRect] = [:]
        let url = folder.appendingPathComponent(Self.catalogName)
        if let data = try? Data(contentsOf: url),
           let catalog = try? JSONDecoder().decode([String: PhotoEditRecord].self, from: data) {
            for (name, rec) in catalog {
                let fileURL = folder.appendingPathComponent(name)
                if !rec.adjustments.isIdentity { edits[fileURL] = rec.adjustments }
                if rec.rotation != 0 { rots[fileURL] = rec.rotation }
                if let c = rec.crop, c != fullCrop { crps[fileURL] = c }
            }
        }
        editsByURL = edits
        rotations = rots
        crops = crps
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
            if let c = crops[photo.url], c != fullCrop { rec.crop = c; edited = true }
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

// Monotonic token used to drop superseded live preview renders. Thread-safe so
// the detached render task can read the latest value while a drag is in flight.
final class RenderGen: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
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

// A single point on the undo timeline: the full edit state for one photo.
struct EditState: Equatable {
    var adj: Adjustments
    var rotation: Int
    var crop: CGRect?
}

// One photo's persisted edit: the adjustment recipe, quarter-turn rotation, and
// an optional normalized crop rect.
struct PhotoEditRecord: Codable, Sendable {
    var adjustments = Adjustments()
    var rotation = 0
    var crop: CGRect?
}

// All slider values are -100...100 with 0 = no change.
struct Adjustments: Equatable, Sendable, Codable {
    var temperature = 0.0
    var tint = 0.0
    var exposure = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var whites = 0.0
    var blacks = 0.0
    var clarity = 0.0
    var vibrance = 0.0
    var saturation = 0.0

    var isIdentity: Bool { self == Adjustments() }

    enum CodingKeys: String, CodingKey {
        case temperature, tint, exposure, contrast, highlights, shadows
        case whites, blacks, clarity, vibrance, saturation
    }

    init(temperature: Double = 0, tint: Double = 0, exposure: Double = 0,
         contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
         whites: Double = 0, blacks: Double = 0, clarity: Double = 0,
         vibrance: Double = 0, saturation: Double = 0) {
        self.temperature = temperature
        self.tint = tint
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.clarity = clarity
        self.vibrance = vibrance
        self.saturation = saturation
    }

    // Decode field-by-field with defaults so catalogs written before a field
    // existed still load — never throw away a user's saved edits on upgrade.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys) -> Double { (try? c.decode(Double.self, forKey: k)) ?? 0 }
        temperature = v(.temperature)
        tint = v(.tint)
        exposure = v(.exposure)
        contrast = v(.contrast)
        highlights = v(.highlights)
        shadows = v(.shadows)
        whites = v(.whites)
        blacks = v(.blacks)
        clarity = v(.clarity)
        vibrance = v(.vibrance)
        saturation = v(.saturation)
    }
}

// Which tonal range a slider reaches, for the "light up what I change" overlay.
enum MaskKind { case shadows, highlights, whites, blacks }

// Mask = the *actual* per-pixel effect of the slider, not an approximation of it.
// We run the real slider curve (at full strength) on the current frame, diff it
// against the unedited frame, and use the magnitude of that difference as the
// glow's alpha. By construction the red lands exactly where — and as much as —
// the slider moves pixels, matching the tone curve's true footprint (including
// the spline's spill into neighboring tones) with no hand-tuning.
func affectedMask(_ image: NSImage, kind: MaskKind) -> NSImage? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let ci = CIImage(cgImage: cg)
    let extent = ci.extent

    func run(_ name: String, _ input: CIImage, _ params: [String: Any]) -> CIImage {
        guard let f = CIFilter(name: name) else { return input }
        f.setValue(input, forKey: kCIInputImageKey)
        for (k, v) in params { f.setValue(v, forKey: k) }
        return f.outputImage ?? input
    }

    // The real slider op at full strength — the same tone-curve point this slider
    // moves in applyAdjustments — so the diff below is precisely what dragging it
    // does, and the glow lands on exactly the tones it reaches.
    let probe: [CIVector]
    switch kind {
    case .shadows:
        probe = [CIVector(x: 0, y: 0), CIVector(x: 0.25, y: 0.45), CIVector(x: 0.5, y: 0.5),
                 CIVector(x: 0.75, y: 0.75), CIVector(x: 1, y: 1)]
    case .highlights:
        probe = [CIVector(x: 0, y: 0), CIVector(x: 0.25, y: 0.25), CIVector(x: 0.5, y: 0.5),
                 CIVector(x: 0.75, y: 0.55), CIVector(x: 1, y: 1)]
    case .whites:
        probe = [CIVector(x: 0, y: 0), CIVector(x: 0.25, y: 0.25), CIVector(x: 0.5, y: 0.5),
                 CIVector(x: 0.75, y: 0.75), CIVector(x: 1, y: 0.8)]
    case .blacks:
        probe = [CIVector(x: 0, y: 0.2), CIVector(x: 0.25, y: 0.37), CIVector(x: 0.5, y: 0.5),
                 CIVector(x: 0.75, y: 0.75), CIVector(x: 1, y: 1)]
    }
    let curved = run("CIToneCurve", ci, [
        "inputPoint0": probe[0], "inputPoint1": probe[1], "inputPoint2": probe[2],
        "inputPoint3": probe[3], "inputPoint4": probe[4]
    ])
    // |curved − original| per channel: the pixels the slider changes, and how much.
    let diff = run("CIDifferenceBlendMode", curved, [kCIInputBackgroundImageKey: ci])

    // Collapse the change to a single weight, amplify it (changes are small), and
    // pour it into alpha under a solid red tint.
    let gain: CGFloat = 5
    let luma = CIVector(x: 0.2126 * gain, y: 0.7152 * gain, z: 0.0722 * gain, w: 0)
    let tint = CIVector(x: 1.0, y: 0.18, z: 0.18, w: 0)
    let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
    var out = run("CIColorMatrix", diff, [
        "inputRVector": zero, "inputGVector": zero, "inputBVector": zero,
        "inputAVector": luma,
        "inputBiasVector": tint
    ])
    out = out.clampedToExtent().applyingGaussianBlur(sigma: 2.5).cropped(to: extent)

    guard let outCG = sharedCIContext.createCGImage(out, from: extent) else { return nil }
    return NSImage(cgImage: outCG, size: NSSize(width: outCG.width, height: outCG.height))
}

func applyAdjustments(_ image: NSImage, _ a: Adjustments) -> NSImage? {
    // Reach the backing CGImage directly. tiffRepresentation would re-encode the
    // whole image to an uncompressed TIFF and decode it back — tens of ms wasted
    // on every drag tick when the NSImage is already CGImage-backed.
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
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
    // One parametric tone curve carries all four region/endpoint controls, with
    // the midpoint pinned at (0.5, 0.5). The pin keeps each slider surgical:
    // Blacks bends only the low end, Whites only the high end, Shadows/Highlights
    // the quarter tones — none of them drag the midtones or scale the whole range.
    if a.shadows != 0 || a.highlights != 0 || a.whites != 0 || a.blacks != 0 {
        apply("CIToneCurve", [
            "inputPoint0": CIVector(x: 0, y: a.blacks / 100 * 0.2),
            "inputPoint1": CIVector(x: 0.25, y: 0.25 + a.shadows / 100 * 0.2 + a.blacks / 100 * 0.12),
            "inputPoint2": CIVector(x: 0.5, y: 0.5),
            "inputPoint3": CIVector(x: 0.75, y: 0.75 + a.highlights / 100 * 0.2),
            "inputPoint4": CIVector(x: 1, y: 1 + a.whites / 100 * 0.2)
        ])
    }
    if a.contrast != 0 || a.saturation != 0 {
        apply("CIColorControls", [
            kCIInputContrastKey: 1 + a.contrast / 100 * 0.3,
            kCIInputSaturationKey: 1 + a.saturation / 100
        ])
    }
    // Vibrance: nonlinear saturation that spares already-saturated colors and skin.
    if a.vibrance != 0 {
        apply("CIVibrance", ["inputAmount": a.vibrance / 100])
    }
    // Clarity: local (midtone) contrast. Radius scales with the image so proxy
    // and full-res match. Positive adds local contrast via unsharp mask; negative
    // can't use unsharp (its intensity clamps at 0), so it blends toward a blur to
    // *reduce* local contrast for a soft look.
    if a.clarity > 0 {
        let r = max(extent.width, extent.height) * 0.012
        apply("CIUnsharpMask", [kCIInputRadiusKey: r, kCIInputIntensityKey: a.clarity / 100 * 0.45])
    } else if a.clarity < 0, let f = CIFilter(name: "CIDissolveTransition") {
        let r = max(extent.width, extent.height) * 0.012
        let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: r).cropped(to: extent)
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(blurred, forKey: kCIInputTargetImageKey)
        f.setValue(-a.clarity / 100 * 0.35, forKey: kCIInputTimeKey)
        ci = f.outputImage ?? ci
    }

    guard let outCG = sharedCIContext.createCGImage(ci, from: extent) else { return nil }
    return NSImage(cgImage: outCG, size: NSSize(width: outCG.width, height: outCG.height))
}

// Renders the edited full-res image and writes it as a JPEG copy alongside the
// original (e.g. "beach.jpg" -> "beach-edited.jpg"). Returns the written URL.
func exportEdited(base: NSImage, adjustments a: Adjustments, turns: Int, crop: CGRect?, originalURL: URL) -> URL? {
    let edited = a.isIdentity ? base : (applyAdjustments(base, a) ?? base)
    let rotated = turns == 0 ? edited : rotatedImage(edited, quarterTurns: turns)
    let final = crop.map { cropped(rotated, to: $0) } ?? rotated
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
    // Reach the backing CGImage directly — tiffRepresentation would re-encode the
    // whole image every frame, which is far too slow to run during a live drag.
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

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
    var name: String = ""
    var desc: String = ""
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var negColor: Color = Color(white: 0.7)
    var posColor: Color = Color(white: 0.7)
    var format: (Double) -> String = ScrubRow.intFormat
    var onEditingChanged: (Bool) -> Void
    var onHoverChanged: (Bool) -> Void = { _ in }

    // Half-width of the magnetic snap zone around center, in value units.
    private let snapZone = 2.0

    @State private var hovering = false
    // 0 at rest, springs to 1 while actively dragging — drives the indicator's
    // pop and glow so grabbing a slider feels physical.
    @State private var grab: CGFloat = 0
    // Physics: the applied value springs toward `target` instead of snapping to it,
    // giving the slider mass — a little catch-up on fast moves, a soft settle on
    // release. Everything (handle, ticks, number, photo) reads `value`, so they all
    // inherit the weight, and it lands exactly on `target` so precision is intact.
    @State private var target: Double = 0
    @State private var vel: Double = 0
    @State private var stretch: CGFloat = 0
    @State private var dragging = false
    @State private var physTimer: Timer?
    @State private var homeArmed = true

    static let intFormat: (Double) -> String = { v in
        v == 0 ? "0" : (v > 0 ? "+\(Int(v))" : "\(Int(v))")
    }

    private func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    // Map the raw drag position to a value, snapping onto center so it isn't
    // slippery, and thump when it lands on a stop (home or either rail).
    private func snapped(fraction f: CGFloat) -> Double {
        let raw = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
        return abs(raw) <= snapZone ? 0 : raw
    }

    // Kick off the spring loop that chases `target`. Idempotent — one timer.
    private func startPhysics() {
        guard physTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { stepPhysics() }
        }
        RunLoop.main.add(timer, forMode: .common)
        physTimer = timer
    }

    // One frame. In the free zone while dragging, `value` is locked to the finger
    // (1:1, fully tactile). The spring only takes over for the discrete moments
    // that should feel physical: the magnetic snap into center, the settle after
    // release, and the double-click glide home. Sub-stepped for stability.
    private func stepPhysics() {
        let prev = value
        if dragging && target != 0 {
            value = target
            vel = 0
        } else {
            let k = 600.0, damp = 34.0
            for _ in 0..<2 {
                let dt = 1.0 / 120
                vel += (target - value) * k * dt
                vel *= exp(-damp * dt)
                value += vel * dt
            }
        }
        value = min(range.upperBound, max(range.lowerBound, value))
        // Stretch spikes with speed, then relaxes — the taffy pull on fast flicks.
        let speed = min(1, CGFloat(abs(value - prev)) / 4)
        stretch = max(speed, stretch * 0.85)
        detent(prev: prev, now: value)

        if !dragging && abs(target - value) < 0.03 && abs(vel) < 0.03 {
            value = target
            vel = 0
            stretch = 0
            physTimer?.invalidate(); physTimer = nil
            grab = 0
            onEditingChanged(false)
            return
        }
        if value != prev { onEditingChanged(true) }
    }

    // Detents: a soft tap when the value lands on its magnetic home or slams a
    // rail — the meaningful stops only, re-armed once it pulls away from center.
    private func detent(prev: Double, now: Double) {
        if target == 0, homeArmed, abs(now) < 0.6 {
            tap(.levelChange); homeArmed = false
        } else if abs(now) > 2 {
            homeArmed = true
        }
        if (now >= range.upperBound && prev < range.upperBound)
            || (now <= range.lowerBound && prev > range.lowerBound) {
            tap(.levelChange)
        }
    }

    var body: some View {
        let active = value != 0
        let fill = value >= 0 ? posColor : negColor

        VStack(alignment: .leading, spacing: 10) {
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
                // While dragging, a soft lens rides the handle: nearby ticks swell
                // taller, fatten, and bloom into the fill color, tapering off with
                // distance. `grab` gates it so the ruler stays flat at rest.
                let sigma = Double(spacing) * 2.3
                for i in 0...count {
                    let tx = margin + CGFloat(i) * spacing
                    let inSpan = tx >= min(cx, vx) - 0.5 && tx <= max(cx, vx) + 0.5
                    let d = Double(tx - vx)
                    let bump = exp(-(d * d) / (2 * sigma * sigma)) * Double(grab)
                    let th = tickH * (1 + bump * 0.5)
                    let width = 1.4 + bump * 0.7
                    var p = Path()
                    p.move(to: CGPoint(x: tx, y: baseY - th / 2))
                    p.addLine(to: CGPoint(x: tx, y: baseY + th / 2))
                    // Cold base grid, then the warm fill blooming on the ticks the
                    // slider spans plus a lens around the handle.
                    ctx.stroke(p, with: .color(.primary.opacity(0.16)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round))
                    // Span fill needs a live value; the lens rides the handle even
                    // through 0, so it isn't gated on `active` (avoids a gray flash
                    // while crossing center).
                    let warmth = max(active && inSpan ? 0.9 : 0, bump * 0.95)
                    if warmth > 0 {
                        ctx.stroke(p, with: .color(fill.opacity(warmth)),
                                   style: StrokeStyle(lineWidth: width, lineCap: .round))
                    }
                }

                // Neutral home dot above the zero mark.
                let dot = CGRect(x: cx - 2, y: 0, width: 4, height: 4)
                ctx.fill(Path(ellipseIn: dot), with: .color(.primary.opacity(0.3)))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            // Live indicator: a capsule that springs bigger and glows on grab.
            .overlay {
                GeometryReader { g in
                    let span = range.upperBound - range.lowerBound
                    let vx = CGFloat((value - range.lowerBound) / span) * g.size.width
                    Capsule()
                        .fill(active ? AnyShapeStyle(fill) : AnyShapeStyle(.primary.opacity(0.45)))
                        .frame(width: 2.5, height: 17)
                        .scaleEffect(x: 1 + grab * 0.4 + stretch * 1.5,
                                     y: 1 + grab * 0.25 - stretch * 0.22, anchor: .center)
                        .shadow(color: (active ? fill : .primary)
                                    .opacity(Double(min(1, grab * 0.7 + stretch * 0.6))),
                                radius: grab * 4 + stretch * 7)
                        .position(x: vx, y: g.size.height - 5.5)
                        .animation(.spring(response: 0.24, dampingFraction: 0.5), value: grab)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                SliderInteraction(
                    fraction: CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)),
                    onChange: { f, _ in
                        target = snapped(fraction: f)
                        grab = 1
                        dragging = true
                        startPhysics()
                    },
                    onEnded: {
                        dragging = false
                        startPhysics()
                    },
                    onReset: {
                        target = 0
                        dragging = false
                        startPhysics()
                    }
                )
            }

            Text(format(value))
                .font(.system(size: 11, weight: active ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(active ? AnyShapeStyle(fill) : AnyShapeStyle(.secondary))
                .frame(width: 30, alignment: .trailing)
                .offset(y: 4)
        }

            if hovering && !desc.isEmpty {
                Text("\(name): \(desc)")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                    // One line, always: the longest labels shrink a hair rather
                    // than wrapping to a second line.
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.15)) { hovering = h }
            onHoverChanged(h)
        }
    }
}

// An AppKit-backed text field. A plain SwiftUI TextField can't be focused in this
// borderless, movable-by-background window (clicks drag the window); overriding
// mouseDownCanMoveWindow on the NSTextField makes clicks land and typing work.
struct VisionTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = ClickableTextField()
        tf.placeholderString = placeholder
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 12)
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.isScrollable = true
        tf.cell?.wraps = false
        tf.delegate = context.coordinator
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: VisionTextField
        init(_ parent: VisionTextField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            if let tf = note.object as? NSTextField { parent.text = tf.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }

    final class ClickableTextField: NSTextField {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

struct SliderInteraction: NSViewRepresentable {
    var fraction: CGFloat                       // current value's position, 0…1
    var onChange: (CGFloat, CGFloat) -> Void    // (fraction 0…1, track width in px)
    var onEnded: () -> Void
    var onReset: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let v = TrackView()
        v.configure(fraction, onChange, onEnded, onReset)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackView)?.configure(fraction, onChange, onEnded, onReset)
    }

    // Relative "grab and push": mouseDown anchors the current value under the
    // cursor, and drag distance moves it from there — so the handle never
    // teleports and Option gears the motion down for fine control.
    final class TrackView: NSView {
        private var fraction: CGFloat = 0
        private var onChange: ((CGFloat, CGFloat) -> Void)?
        private var onEnded: (() -> Void)?
        private var onReset: (() -> Void)?
        private var anchorX: CGFloat = 0
        private var anchorFraction: CGFloat = 0

        func configure(_ f: CGFloat, _ c: @escaping (CGFloat, CGFloat) -> Void,
                       _ e: @escaping () -> Void, _ r: (() -> Void)?) {
            fraction = f; onChange = c; onEnded = e; onReset = r
        }

        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onReset?(); return }
            anchorX = convert(event.locationInWindow, from: nil).x
            anchorFraction = fraction
        }
        override func mouseDragged(with event: NSEvent) {
            let w = max(1, bounds.width)
            let x = convert(event.locationInWindow, from: nil).x
            let gain: CGFloat = event.modifierFlags.contains(.option) ? 0.18 : 1.0
            let f = anchorFraction + (x - anchorX) / w * gain
            onChange?(max(0, min(1, f)), w)
        }
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


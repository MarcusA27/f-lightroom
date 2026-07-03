import SwiftUI
import AppKit

// Captures arrow keys / F for photo navigation without needing SwiftUI focus.
struct KeyCatcher: NSViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onFullScreen: () -> Void
    let onRotate: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyView()
        view.onLeft = onLeft
        view.onRight = onRight
        view.onFullScreen = onFullScreen
        view.onRotate = onRotate
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyView else { return }
        view.onLeft = onLeft
        view.onRight = onRight
        view.onFullScreen = onFullScreen
        view.onRotate = onRotate
    }

    final class KeyView: NSView {
        var onLeft: (() -> Void)?
        var onRight: (() -> Void)?
        var onFullScreen: (() -> Void)?
        var onRotate: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: onLeft?()        // left arrow
            case 124: onRight?()       // right arrow
            case 3:   onFullScreen?()  // f
            case 15:  onRotate?()      // r
            default:  super.keyDown(with: event)
            }
        }
    }
}

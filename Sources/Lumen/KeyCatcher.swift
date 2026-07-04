import SwiftUI
import AppKit

// Routes key presses to photo actions. Uses a local NSEvent monitor rather than
// first-responder handling: the window is borderless and SwiftUI keeps stealing
// first responder, so a plain keyDown-override NSView never sees the events.
struct KeyCatcher: NSViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onFullScreen: () -> Void
    let onRotate: () -> Void
    var onCompareDown: () -> Void = {}
    var onCompareUp: () -> Void = {}
    var onEscape: () -> Void = {}
    var onShift: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.parent = self
        context.coordinator.install()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        var parent: KeyCatcher
        private var monitor: Any?

        init(_ parent: KeyCatcher) { self.parent = parent }

        func install() {
            guard monitor == nil else { return }
            // Local monitors are delivered on the main thread. NSEvent isn't
            // Sendable, so pull out the plain fields we need before hopping.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                let type = event.type
                let mods = event.modifierFlags
                // charactersIgnoringModifiers throws on flagsChanged events, so
                // handle modifier transitions before touching any key-only field.
                if type == .flagsChanged {
                    let shift = mods.contains(.shift)
                    MainActor.assumeIsolated { self?.parent.onShift(shift) }
                    return event
                }
                let chars = event.charactersIgnoringModifiers
                let keyCode = event.keyCode
                let isRepeat = event.isARepeat
                let handled = MainActor.assumeIsolated {
                    self?.handle(type: type, chars: chars, keyCode: keyCode,
                                 isRepeat: isRepeat, mods: mods) ?? false
                }
                return handled ? nil : event
            }
        }

        func remove() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }

        // Returns true when the key was consumed (swallow it to avoid the system
        // beep); false lets it flow on to menu shortcuts and the responder chain.
        private func handle(type: NSEvent.EventType, chars: String?, keyCode: UInt16,
                            isRepeat: Bool, mods: NSEvent.ModifierFlags) -> Bool {
            // If a text field is being edited (its field editor is first responder),
            // let every key through so typing "f", arrows, etc. reach the field.
            if NSApp.keyWindow?.firstResponder is NSText { return false }
            // Let ⌘/⌃ combos through to menu shortcuts (Open, Save, Minimize…).
            if mods.contains(.command) || mods.contains(.control) { return false }

            if type == .keyUp {
                if chars == "\\" { parent.onCompareUp(); return true }
                return false
            }

            switch chars {
            case "\\":
                if !isRepeat { parent.onCompareDown() }
                return true
            case "f":
                parent.onFullScreen(); return true
            default:
                switch keyCode {
                case 123: parent.onLeft(); return true    // left arrow
                case 124: parent.onRight(); return true   // right arrow
                case 53:  parent.onEscape(); return true  // escape
                default:  return false                    // r rotate / c crop handled by menu
                }
            }
        }
    }
}

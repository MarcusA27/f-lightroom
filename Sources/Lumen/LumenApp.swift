import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            guard let window = NSApp.windows.first else { return }
            window.isRestorable = false
            window.styleMask = [.borderless, .resizable, .miniaturizable]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.cornerRadius = 0
            window.contentView?.layer?.masksToBounds = true
            window.setContentSize(NSSize(width: 920, height: 750))
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Photos") {
            ContentView()
                .frame(minWidth: 760, minHeight: 420)
        }
        .defaultSize(width: 920, height: 750)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NotificationCenter.default.post(name: .undoEdit, object: nil)
                }
                .keyboardShortcut("z", modifiers: .command)
                Button("Redo") {
                    NotificationCenter.default.post(name: .redoEdit, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    NotificationCenter.default.post(name: .chooseFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save a Copy…") {
                    NotificationCenter.default.post(name: .exportPhoto, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            CommandGroup(after: .windowSize) {
                Button("Minimize") { NSApp.keyWindow?.miniaturize(nil) }
                    .keyboardShortcut("m", modifiers: .command)
            }
            CommandMenu("Image") {
                Button("Rotate Right") {
                    NotificationCenter.default.post(name: .rotateRight, object: nil)
                }
                .keyboardShortcut("r", modifiers: [])
                Button("Crop") {
                    NotificationCenter.default.post(name: .cropToggle, object: nil)
                }
                .keyboardShortcut("c", modifiers: [])
                Button("Describe Vision…") {
                    NotificationCenter.default.post(name: .describeVision, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

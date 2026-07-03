import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct Photo: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
}

@MainActor
final class PhotoLibrary: ObservableObject {
    @Published private(set) var photos: [Photo] = []
    @Published private(set) var folderName: String?
    @Published private(set) var isLoading = false
    @Published private(set) var recentFolders: [URL] = []

    private nonisolated static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif",
        "tiff", "tif", "bmp", "webp", "jp2"
    ]

    init() {
        recentFolders = Self.storedRecents()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of photos"

        let response = panel.runModal()

        // The modal panel leaves the borderless main window non-key, which makes
        // its controls and window-dragging stop responding. Re-activate it.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)

        guard response == .OK, let url = panel.url else { return }
        load(folder: url)
    }

    func load(folder url: URL) {
        isLoading = true
        folderName = url.lastPathComponent
        photos = []
        UserDefaults.standard.set(url.path, forKey: Self.lastFolderKey)
        pushRecent(url)

        Task.detached(priority: .userInitiated) {
            let found = Self.scan(folder: url)
            await MainActor.run {
                self.photos = found
                self.isLoading = false
            }
        }
    }

    private static let lastFolderKey = "lastFolderPath"
    private nonisolated static let recentsKey = "recentFolders"
    private static let maxRecents = 12

    // Reopen the folder from the previous session, if it still exists.
    func restoreLastFolder() {
        guard photos.isEmpty,
              let path = UserDefaults.standard.string(forKey: Self.lastFolderKey) else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
        else { return }
        load(folder: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func pushRecent(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(Self.maxRecents)), forKey: Self.recentsKey)
        recentFolders = Self.storedRecents()
    }

    private nonisolated static func storedRecents() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: recentsKey) ?? [])
            .filter { path in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // Cover image (first photo) and count for a recents card. Runs off-main.
    nonisolated static func summarize(folder url: URL) -> (cover: URL?, count: Int) {
        let found = scan(folder: url)
        return (found.first?.url, found.count)
    }

    private nonisolated static func scan(folder url: URL) -> [Photo] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return items
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Photo(url: $0) }
    }
}

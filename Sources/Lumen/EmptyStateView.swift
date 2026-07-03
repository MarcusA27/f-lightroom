import SwiftUI
import UniformTypeIdentifiers

// Shown until a folder is open: a launcher of recent folders on top, tips below.
struct EmptyStateView: View {
    let recents: [URL]
    let onOpen: (URL) -> Void
    let onChoose: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            if recents.isEmpty {
                heroPrompt
            } else {
                recentsGrid
            }

            Divider()
            tipsFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Recents

    private var recentsGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Recent")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onChoose) {
                        Label("Open Folder", systemImage: "folder")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(recents, id: \.self) { url in
                        RecentFolderCard(url: url) { onOpen(url) }
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Empty hero (no recents yet)

    private var heroPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No folder open")
                .font(.title2.weight(.medium))
            Text("Press ⌘O or drop a folder here to begin.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Tips footer

    private var tipsFooter: some View {
        HStack(spacing: 18) {
            tip("⌘O", "Open")
            tip("← →", "Browse")
            tip("R", "Rotate")
            tip("F", "Full screen")
        }
        .font(.system(size: 12))
        .foregroundStyle(.tertiary)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    private func tip(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key).monospaced().foregroundStyle(.secondary)
            Text(label)
        }
    }
}

private struct RecentFolderCard: View {
    let url: URL
    let onOpen: () -> Void

    @State private var cover: URL?
    @State private var count = 0
    @State private var loaded = false
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    if let cover {
                        ThumbnailView(url: cover, maxPixel: 400)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else if loaded {
                        Image(systemName: "folder")
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 108)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(loaded ? "\(count) photo\(count == 1 ? "" : "s")" : " ")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task(id: url) {
            let summary = await Task.detached(priority: .userInitiated) {
                PhotoLibrary.summarize(folder: url)
            }.value
            cover = summary.cover
            count = summary.count
            loaded = true
        }
    }
}

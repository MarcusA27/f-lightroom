import SwiftUI
import ImageIO
import AppKit

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [URL: NSImage] = [:]

    func thumbnail(for url: URL, maxPixel: Int) -> NSImage? {
        if let cached = cache[url] { return cached }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let image = NSImage(cgImage: cg, size: .zero)
        cache[url] = image
        return image
    }
}

struct ThumbnailView: View {
    let url: URL
    let maxPixel: Int
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color(nsColor: .quaternaryLabelColor))
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: url) {
            image = nil
            let loaded = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: maxPixel)
            if !Task.isCancelled { image = loaded }
        }
    }
}

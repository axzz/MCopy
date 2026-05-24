import AppKit
import SwiftData
import UniformTypeIdentifiers

class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int
    private let store: ClipboardStore
    private var shouldIgnoreNextChange = false

    init(store: ClipboardStore) {
        self.store = store
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func ignoreNextChange() {
        shouldIgnoreNextChange = true
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        if shouldIgnoreNextChange {
            shouldIgnoreNextChange = false
            return
        }

        guard let item = extractItem(from: pb) else { return }
        store.insert(item)
    }

    private func extractItem(from pb: NSPasteboard) -> ClipboardItem? {
        // File URLs first — Finder copies include both the file URL and a rendered
        // icon image, so checking NSImage first would misclassify PDFs/HEIC/Pages
        // files as images.
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: fileOptions)?
            .compactMap({ $0 as? URL }),
           !urls.isEmpty {
            let paths = urls.map(\.path).joined(separator: "\n")
            // If the first file is an image, generate and cache a thumbnail now
            // while the pasteboard still grants read access — under App Sandbox,
            // reading the path later (in CardView) would fail.
            let thumb = urls.first.flatMap(Self.imageThumbnail(forFileAt:))
            return ClipboardItem(contentType: .file, textContent: paths, thumbnailData: thumb)
        }

        // Image (screenshots, in-app copies — no file URL present)
        if let image = pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let tiff = image.tiffRepresentation {
            let thumb = Self.imageThumbnail(fromImageData: tiff)
            return ClipboardItem(contentType: .image, imageData: tiff, thumbnailData: thumb)
        }

        // String → detect URL vs plain text
        if let text = pb.string(forType: .string), !text.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed),
               let scheme = url.scheme, !scheme.isEmpty,
               url.host != nil {
                return ClipboardItem(contentType: .url, textContent: trimmed)
            }
            return ClipboardItem(contentType: .text, textContent: text)
        }

        return nil
    }

    /// Returns a downscaled JPEG thumbnail for image files, or nil otherwise.
    /// Called at capture time so reads happen while pasteboard access is granted.
    private static func imageThumbnail(forFileAt url: URL) -> Data? {
        let ext = url.pathExtension
        guard !ext.isEmpty,
              let utType = UTType(filenameExtension: ext),
              utType.conforms(to: .image) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnailData(from: source)
    }

    /// Same downscaling logic, but for in-memory image bytes (e.g. pasteboard TIFF).
    static func imageThumbnail(fromImageData data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnailData(from: source)
    }

    private static func thumbnailData(from source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

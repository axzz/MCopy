import AppKit
import SwiftData
import UniformTypeIdentifiers

class ClipboardMonitor {
    /// Upper bound on a single RTF or HTML payload we keep. 512 KB comfortably
    /// fits normal styled prose; oversize payloads usually come from webpages
    /// embedding base64 images and aren't worth the storage cost.
    private static let maxRichTextBytes = 512 * 1024

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
            let thumb = Self.imageThumbnail(from: image)
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
            // Capture rich-text representations alongside the plain string so
            // paste preserves formatting in rich-text-aware receivers. Sources
            // vary: Notes/Word/Pages provide RTF, web browsers often only HTML.
            // Cap each payload — webpage HTML routinely embeds base64 images or
            // megabytes of inline CSS, and SwiftData would bloat fast. Past the
            // cap we drop the rich payload and fall back to plain text on paste.
            let rtf = Self.boundedRichText(pb.data(forType: .rtf))
            let html = Self.boundedRichText(pb.data(forType: .html))
            return ClipboardItem(
                contentType: .text,
                textContent: text,
                rtfData: rtf,
                htmlData: html
            )
        }

        return nil
    }

    /// Passes through the data when present and within `maxRichTextBytes`;
    /// returns nil otherwise so the item falls back to plain text on paste.
    private static func boundedRichText(_ data: Data?) -> Data? {
        guard let data, data.count <= maxRichTextBytes else { return nil }
        return data
    }

    /// Returns a downscaled JPEG thumbnail for image files, or nil otherwise.
    /// Called at capture time so reads happen while pasteboard access is granted.
    private static func imageThumbnail(forFileAt url: URL) -> Data? {
        let ext = url.pathExtension
        guard !ext.isEmpty,
              let utType = UTType(filenameExtension: ext),
              utType.conforms(to: .image) else { return nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        return imageThumbnail(from: image)
    }

    /// Same downscaling logic, but for in-memory image bytes (e.g. pasteboard TIFF).
    static func imageThumbnail(fromImageData data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        return imageThumbnail(from: image)
    }

    private static func imageThumbnail(from image: NSImage) -> Data? {
        guard let rep = canonicalBitmap(from: image, maxPixelSize: 400) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    private static func canonicalBitmap(from image: NSImage, maxPixelSize: CGFloat) -> NSBitmapImageRep? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let scale = min(1, maxPixelSize / max(sourceSize.width, sourceSize.height))
        let targetSize = NSSize(
            width: max(1, floor(sourceSize.width * scale)),
            height: max(1, floor(sourceSize.height * scale))
        )

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        context?.imageInterpolation = .high
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        return rep
    }
}

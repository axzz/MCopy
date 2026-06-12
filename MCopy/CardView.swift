import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Decoded-image cache keyed by ClipboardItem.id.
/// CGImage rendering avoids SwiftUI reinterpreting AppKit image coordinates on
/// repeated card re-renders.
enum ImagePreviewCache {
    private static let cache: NSCache<NSString, CGImageBox> = {
        let c = NSCache<NSString, CGImageBox>()
        c.countLimit = ClipboardStore.capacity
        return c
    }()

    static func image(for id: UUID, data: Data) -> CGImage? {
        let key = id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        guard let nsImage = NSImage(data: data),
              let image = canonicalCGImage(from: nsImage) else { return nil }
        cache.setObject(CGImageBox(image), forKey: key)
        return image
    }

    static func image(forFileAt path: String) -> CGImage? {
        let key = "file:\(path)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        let url = URL(fileURLWithPath: path)
        guard let nsImage = NSImage(contentsOf: url),
              let image = canonicalCGImage(from: nsImage) else { return nil }
        cache.setObject(CGImageBox(image), forKey: key)
        return image
    }

    private static func canonicalCGImage(from image: NSImage) -> CGImage? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let maxPixelSize: CGFloat = 400
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

        return rep.cgImage
    }
}

private final class CGImageBox {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

struct CardView: View {
    let item: ClipboardItem
    let isSelected: Bool
    var onTogglePin: () -> Void

    private let cardWidth: CGFloat    = 190
    private let titleHeight: CGFloat  = 40
    private let contentHeight: CGFloat = 115

    var body: some View {
        VStack(spacing: 0) {
            titleSection
            contentSection
            footerSection
        }
        .frame(width: cardWidth)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isSelected
                        ? Color(red: 0.25, green: 0.52, blue: 1.0)
                        : Color.white.opacity(0.1),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
        .shadow(color: .black.opacity(0.3), radius: isSelected ? 10 : 5, y: 3)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    // MARK: - Title section (colored top bar)

    private var titleSection: some View {
        HStack(spacing: 6) {
            Text(item.cardTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()

            Button(action: onTogglePin) {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(item.isPinned ? .white : .white.opacity(0.58))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.isPinned ? "Unpin" : "Pin")
            .animation(.easeInOut(duration: 0.14), value: item.isPinned)
        }
        .padding(.horizontal, 11)
        .frame(height: titleHeight)
        .background(item.titleBarColor)
    }

    // MARK: - Content section (dark preview area)

    private var contentSection: some View {
        Group {
            switch item.type {
            case .image:
                imagePreview
            case .file:
                filePreview
            default:
                Text(item.textContent ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(red: 0.78, green: 0.78, blue: 0.80))
                    .lineLimit(7)
                    .truncationMode(.tail)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(height: contentHeight)
        .background(Color(red: 0.14, green: 0.14, blue: 0.155))
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let data = item.imageData ?? item.thumbnailData,
           let image = ImagePreviewCache.image(for: item.id, data: data) {
            cgImageView(image)
        } else {
            Image(systemName: "photo")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.2))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var filePreview: some View {
        let paths = (item.textContent ?? "")
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
        let firstPath = paths.first ?? ""

        let thumbImage: CGImage? = {
            if let data = item.thumbnailData ?? item.imageData,
               let img = ImagePreviewCache.image(for: item.id, data: data) { return img }
            if isImageFile(firstPath) { return ImagePreviewCache.image(forFileAt: firstPath) }
            return nil
        }()

        if let image = thumbImage {
            ZStack(alignment: .bottomTrailing) {
                cgImageView(image)

                if paths.count > 1 {
                    Text("+\(paths.count - 1)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                        .padding(6)
                }
            }
        } else {
            let icon = NSWorkspace.shared.icon(forFile: firstPath)
            let name = URL(fileURLWithPath: firstPath).lastPathComponent

            VStack(spacing: 6) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 60, height: 60)

                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.85, green: 0.85, blue: 0.87))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)

                if paths.count > 1 {
                    Text("+\(paths.count - 1) more")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cgImageView(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1, orientation: .up)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isImageFile(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 4) {
            Image(systemName: item.typeIcon)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))

            if let count = item.charCount {
                Text(count)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
            }

            Spacer()

            Text(item.timeAgo)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.25))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(red: 0.12, green: 0.12, blue: 0.135))
    }
}

// MARK: - ClipboardItem display extensions

extension ClipboardItem {
    /// Short title shown in the colored top bar.
    var cardTitle: String {
        switch type {
        case .text:
            let first = (textContent ?? "")
                .components(separatedBy: "\n")
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            return first.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : first
        case .url:
            if let url = URL(string: textContent ?? ""), let host = url.host {
                return host.replacingOccurrences(of: "www.", with: "")
            }
            return "Link"
        case .image:
            return "Image"
        case .file:
            let path = textContent?.components(separatedBy: "\n").first ?? ""
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name.isEmpty ? "File" : name
        }
    }

    /// True when this is a `.file` whose first path is an image file.
    /// Such items stay classified as `.file` so paste yields a file URL, but
    /// we render them with the image visual treatment for consistency.
    var isImageFile: Bool {
        guard type == .file,
              let first = textContent?.components(separatedBy: "\n").first,
              !first.isEmpty else { return false }
        let ext = URL(fileURLWithPath: first).pathExtension
        guard !ext.isEmpty, let utType = UTType(filenameExtension: ext) else { return false }
        return utType.conforms(to: .image)
    }

    /// Title bar background color keyed to content type.
    var titleBarColor: Color {
        if isImageFile { return Color(red: 0.52, green: 0.30, blue: 0.72) }
        switch type {
        case .text:  return Color(red: 0.36, green: 0.38, blue: 0.44)   // brighter slate
        case .url:   return Color(red: 0.24, green: 0.50, blue: 0.85)   // bright blue
        case .image: return Color(red: 0.52, green: 0.30, blue: 0.72)   // bright purple
        case .file:  return Color(red: 0.22, green: 0.62, blue: 0.50)   // bright teal
        }
    }

    var typeIcon: String {
        if isImageFile { return "photo" }
        switch type {
        case .text:  return "doc.text"
        case .image: return "photo"
        case .url:   return "link"
        case .file:  return "folder"
        }
    }

    var charCount: String? {
        guard type == .text || type == .url,
              let text = textContent, !text.isEmpty else { return nil }
        return "\(text.count) characters"
    }

    var timeAgo: String {
        let diff = Date().timeIntervalSince(timestamp)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        return "\(Int(diff / 86400))d ago"
    }
}

import Foundation
import SwiftData
import AppKit

enum ClipboardContentType: String, Codable {
    case text
    case image
    case url
    case file
}

@Model
final class ClipboardItem {
    var id: UUID
    var contentType: String
    var textContent: String?
    /// RTF representation captured alongside plain text. Preserves formatting
    /// (bold, color, font, etc.) so paste into a rich-text-aware app keeps the
    /// original styling.
    var rtfData: Data?
    /// HTML representation. Some sources (web browsers) only provide HTML, not
    /// RTF — keeping both lets receivers pick the highest-fidelity format they
    /// support.
    var htmlData: Data?
    /// Original payload — used when writing back to the pasteboard so paste
    /// keeps full fidelity (e.g. a full-resolution screenshot).
    var imageData: Data?
    /// Small JPEG generated at capture time for fast preview rendering.
    /// Optional and additive — old rows simply have nil and fall back to imageData.
    var thumbnailData: Data?
    var isPinned: Bool
    var pinnedAt: Date?
    var timestamp: Date

    init(
        contentType: ClipboardContentType,
        textContent: String? = nil,
        rtfData: Data? = nil,
        htmlData: Data? = nil,
        imageData: Data? = nil,
        thumbnailData: Data? = nil,
        isPinned: Bool = false,
        pinnedAt: Date? = nil
    ) {
        self.id = UUID()
        self.contentType = contentType.rawValue
        self.textContent = textContent
        self.rtfData = rtfData
        self.htmlData = htmlData
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
        self.timestamp = Date()
    }

    var type: ClipboardContentType {
        ClipboardContentType(rawValue: contentType) ?? .text
    }

    func writeToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch type {
        case .text, .url:
            // Write richest formats first so receivers can pick the
            // highest-fidelity representation they support. Plain string is
            // always set as a fallback for terminals/plain-text fields.
            if let rtfData {
                pb.setData(rtfData, forType: .rtf)
            }
            if let htmlData {
                pb.setData(htmlData, forType: .html)
            }
            if let text = textContent {
                pb.setString(text, forType: .string)
            }
        case .image:
            if let data = imageData {
                pb.setData(data, forType: .tiff)
            }
        case .file:
            let urls = (textContent ?? "")
                .components(separatedBy: "\n")
                .map { URL(fileURLWithPath: $0) as NSURL }
            pb.writeObjects(urls)
        }
    }
}

import AppKit
import MarkdownStickiesCore
import UniformTypeIdentifiers

enum NoteImageStore {
    /// `{safeNoteBase}-img-yyyyMMdd-HHmmss-SSS.{ext}` in the same folder as the note.
    private static func imageBasename(for noteURL: URL) -> String {
        let raw = noteURL.deletingPathExtension().lastPathComponent
        let slug = NoteFilename.slugify(raw)
        return slug.isEmpty ? "note" : slug
    }

    static func saveImage(_ image: NSImage, nextToNote noteURL: URL) throws -> String {
        let folder = noteURL.deletingLastPathComponent()
        let base = imageBasename(for: noteURL)
        let stamp = Self.timestampFormatter.string(from: Date())
        let filename = "\(base)-img-\(stamp).png"
        let fileURL = folder.appendingPathComponent(filename)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            throw StoreError.encodeFailed
        }

        try png.write(to: fileURL, options: .atomic)
        return "./\(filename)"
    }

    /// True when `fileURL` already lives in the note's folder (no copy needed).
    static func isInNoteFolder(_ fileURL: URL, noteURL: URL) -> Bool {
        let folder = noteURL.deletingLastPathComponent().standardizedFileURL
        return fileURL.standardizedFileURL.deletingLastPathComponent() == folder
    }

    static func saveImageFile(from sourceURL: URL, nextToNote noteURL: URL) throws -> String {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let folder = noteURL.deletingLastPathComponent().standardizedFileURL
        let source = sourceURL.standardizedFileURL

        // Already sitting next to the note — link in place, don't duplicate.
        if source.deletingLastPathComponent() == folder {
            return "./\(source.lastPathComponent)"
        }

        let base = imageBasename(for: noteURL)
        let stamp = Self.timestampFormatter.string(from: Date())
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let filename = "\(base)-img-\(stamp).\(ext)"
        let dest = folder.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return "./\(filename)"
    }

    static func saveImageData(_ data: Data, extension ext: String, nextToNote noteURL: URL) throws -> String {
        let folder = noteURL.deletingLastPathComponent()
        let base = imageBasename(for: noteURL)
        let stamp = Self.timestampFormatter.string(from: Date())
        let safeExt = ext.isEmpty ? "png" : ext.lowercased()
        let filename = "\(base)-img-\(stamp).\(safeExt)"
        let dest = folder.appendingPathComponent(filename)
        try data.write(to: dest, options: .atomic)
        return "./\(filename)"
    }

    /// Decode a `data:image/…;base64,…` URL from an HTML5 drop.
    static func saveImageDataURL(_ dataURL: String, nextToNote noteURL: URL) throws -> String {
        guard dataURL.hasPrefix("data:"),
              let comma = dataURL.firstIndex(of: ",")
        else { throw StoreError.encodeFailed }
        let meta = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma])
        let b64 = String(dataURL[dataURL.index(after: comma)...])
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), !data.isEmpty else {
            throw StoreError.encodeFailed
        }
        var ext = "png"
        if meta.contains("image/jpeg") || meta.contains("image/jpg") { ext = "jpg" }
        else if meta.contains("image/gif") { ext = "gif" }
        else if meta.contains("image/webp") { ext = "webp" }
        else if meta.contains("image/heic") { ext = "heic" }
        else if meta.contains("image/tiff") { ext = "tiff" }
        else if meta.contains("image/bmp") { ext = "bmp" }
        return try saveImageData(data, extension: ext, nextToNote: noteURL)
    }

    static func markdownSnippet(relativePath: String, alt: String = "image") -> String {
        // Spaces/parens break unquoted markdown destinations — use <…> when needed.
        if relativePath.contains(where: { $0.isWhitespace || $0 == "(" || $0 == ")" }) {
            return "![\(alt)](<\(relativePath)>)"
        }
        return "![\(alt)](\(relativePath))"
    }

    static func imageFromClipboard() -> NSImage? {
        let pb = NSPasteboard.general
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = images.first {
            return first
        }
        // Raw image data types
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }

    static func clipboardHasImage() -> Bool {
        imageFromClipboard() != nil
    }

    static func imageURLs(from draggingInfo: NSDraggingInfo) -> [URL] {
        let pb = draggingInfo.draggingPasteboard
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic"]

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]) as? [URL], !urls.isEmpty {
            return urls
        }

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] {
            let filtered = urls.filter { imageExts.contains($0.pathExtension.lowercased()) }
            if !filtered.isEmpty { return filtered }
        }

        // Legacy Finder pasteboard
        if let paths = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return paths
                .map { URL(fileURLWithPath: $0) }
                .filter { imageExts.contains($0.pathExtension.lowercased()) }
        }

        return []
    }

    static func imageFromDragging(_ draggingInfo: NSDraggingInfo) -> NSImage? {
        if let url = imageURLs(from: draggingInfo).first {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if let image = NSImage(contentsOf: url) { return image }
        }
        let pb = draggingInfo.draggingPasteboard
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            return images.first
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }

    enum StoreError: Error {
        case encodeFailed
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()
}

import AppKit
import UniformTypeIdentifiers

enum NoteImageStore {
    /// `{noteBase}-img-yyyyMMdd-HHmmss.SSS.{ext}` in the same folder as the note.
    static func saveImage(_ image: NSImage, nextToNote noteURL: URL) throws -> String {
        let folder = noteURL.deletingLastPathComponent()
        let base = noteURL.deletingPathExtension().lastPathComponent
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

    static func saveImageFile(from sourceURL: URL, nextToNote noteURL: URL) throws -> String {
        let folder = noteURL.deletingLastPathComponent()
        let base = noteURL.deletingPathExtension().lastPathComponent
        let stamp = Self.timestampFormatter.string(from: Date())
        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let filename = "\(base)-img-\(stamp).\(ext)"
        let dest = folder.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return "./\(filename)"
    }

    static func markdownSnippet(relativePath: String, alt: String = "image") -> String {
        "![\(alt)](\(relativePath))"
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
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] else { return [] }

        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic"]
        return urls.filter { imageExts.contains($0.pathExtension.lowercased()) }
    }

    static func imageFromDragging(_ draggingInfo: NSDraggingInfo) -> NSImage? {
        if let urls = imageURLs(from: draggingInfo).first {
            return NSImage(contentsOf: urls)
        }
        let pb = draggingInfo.draggingPasteboard
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            return images.first
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

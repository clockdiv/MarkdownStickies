import CryptoKit
import Foundation

/// Metadata for an image that sits next to a synced note.
public struct SyncAssetOffer: Codable, Equatable, Sendable, Hashable {
    public var noteID: UUID
    /// Filename only (e.g. `note-img-….png`), no `./` or directories.
    public var relativePath: String
    public var modifiedAt: Date
    public var sha256: String
    public var byteCount: Int

    public init(
        noteID: UUID,
        relativePath: String,
        modifiedAt: Date,
        sha256: String,
        byteCount: Int
    ) {
        self.noteID = noteID
        self.relativePath = relativePath
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    public var key: String { "\(noteID.uuidString.lowercased())|\(relativePath)" }
}

/// Image bytes for LAN transfer (base64 inside the JSON frame).
public struct SyncAssetBlob: Codable, Equatable, Sendable {
    public var noteID: UUID
    public var relativePath: String
    public var modifiedAt: Date
    public var sha256: String
    public var dataBase64: String

    public init(
        noteID: UUID,
        relativePath: String,
        modifiedAt: Date,
        sha256: String,
        dataBase64: String
    ) {
        self.noteID = noteID
        self.relativePath = relativePath
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
        self.dataBase64 = dataBase64
    }
}

/// Discover / load / apply note-adjacent images for LAN sync.
public enum SyncImageAssets {
    /// Soft cap so one photo + JSON/base64 stays under the 32 MB frame limit.
    public static let maxAssetBytes = 20 * 1024 * 1024

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic"
    ]

    /// Relative image basenames from markdown (`./x.png`, `photos/x.png`, `<./x.png>`).
    /// Directory prefixes are stripped; the markdown itself is left unchanged.
    public static func relativeImageFilenames(in markdown: String) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for dest in rawImageDestinations(in: markdown) {
            guard let name = sanitizedFilename(dest) else { continue }
            if seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }

    /// Offers for every image referenced by notes under `roots` that exists on disk.
    public static func offers(roots: [URL]) -> [SyncAssetOffer] {
        let notes = NoteScanner.scan(roots: roots)
        var offers: [SyncAssetOffer] = []
        var seenKeys = Set<String>()
        for note in notes {
            guard !SyncDebugLog.isDebugNote(url: note.path) else { continue }
            guard let text = try? String(contentsOf: note.path, encoding: .utf8),
                  let id = NoteFrontmatter.syncID(in: text)
            else { continue }
            let folder = note.path.deletingLastPathComponent()
            for dest in rawImageDestinations(in: text) {
                guard let name = sanitizedFilename(dest),
                      let file = resolveExistingImageURL(dest, noteDirectory: folder),
                      let offer = makeOffer(noteID: id, fileURL: file, relativePath: name)
                else { continue }
                if seenKeys.insert(offer.key).inserted {
                    offers.append(offer)
                }
            }
        }
        return offers
    }

    public static func makeOffer(noteID: UUID, fileURL: URL, relativePath: String) -> SyncAssetOffer? {
        guard sanitizedFilename(relativePath) != nil else { return nil }
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let size = values?.fileSize ?? 0
        guard size > 0, size <= maxAssetBytes else { return nil }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        let digest = SHA256.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let mtime = values?.contentModificationDate ?? Date.distantPast
        return SyncAssetOffer(
            noteID: noteID,
            relativePath: relativePath,
            modifiedAt: mtime,
            sha256: hash,
            byteCount: data.count
        )
    }

    public static func loadBlob(offer: SyncAssetOffer, roots: [URL]) -> SyncAssetBlob? {
        guard let name = sanitizedFilename(offer.relativePath),
              let notePath = SyncCatalogBuilder.pathIndex(roots: roots)[offer.noteID]
        else { return nil }
        let folder = notePath.deletingLastPathComponent()
        let text = try? String(contentsOf: notePath, encoding: .utf8)
        guard let file = findImageFile(
            basename: name,
            noteDirectory: folder,
            markdown: text
        ),
              let data = try? Data(contentsOf: file),
              !data.isEmpty
        else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == offer.sha256 else { return nil }
        return SyncAssetBlob(
            noteID: offer.noteID,
            relativePath: name,
            modifiedAt: offer.modifiedAt,
            sha256: offer.sha256,
            dataBase64: data.base64EncodedString()
        )
    }

    /// Offers from `theirs` that we should download (missing or different hash).
    public static func missingOffers(
        theirs: [SyncAssetOffer],
        ours: [SyncAssetOffer]
    ) -> [SyncAssetOffer] {
        let ourByKey = Dictionary(uniqueKeysWithValues: ours.map { ($0.key, $0) })
        return theirs.filter { offer in
            guard let local = ourByKey[offer.key] else { return true }
            return local.sha256 != offer.sha256
        }
    }

    /// Write a received blob next to the local note (basename only — flat vault layout).
    @discardableResult
    public static func applyBlob(_ blob: SyncAssetBlob, roots: [URL]) throws -> URL? {
        guard let name = sanitizedFilename(blob.relativePath) else { return nil }
        guard let notePath = SyncCatalogBuilder.pathIndex(roots: roots)[blob.noteID] else {
            return nil
        }
        guard let data = Data(base64Encoded: blob.dataBase64, options: .ignoreUnknownCharacters),
              !data.isEmpty,
              data.count <= maxAssetBytes
        else {
            throw SyncProtocolError.connectionFailed("Invalid image payload.")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == blob.sha256 else {
            throw SyncProtocolError.connectionFailed("Image checksum mismatch.")
        }

        let dest = notePath.deletingLastPathComponent().appendingPathComponent(name)
        if let existing = try? Data(contentsOf: dest),
           SHA256.hash(data: existing).map({ String(format: "%02x", $0) }).joined() == digest {
            return dest
        }
        try data.write(to: dest, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: blob.modifiedAt],
            ofItemAtPath: dest.path
        )
        return dest
    }

    /// Resolve a markdown image destination to a local file URL for opening / sync.
    /// Keeps structured paths when the file exists (Mac); otherwise falls back to basename
    /// next to the note (flat iOS vault). Does not rewrite markdown.
    public static func resolveImageURL(_ raw: String, noteDirectory: URL) -> URL? {
        let dest = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if dest.hasPrefix("http://") || dest.hasPrefix("https://") {
            return URL(string: dest)
        }
        if dest.hasPrefix("file:") {
            return URL(string: dest)
        }
        guard let name = sanitizedFilename(dest) else { return nil }
        if let existing = resolveExistingImageURL(dest, noteDirectory: noteDirectory) {
            return existing
        }
        return noteDirectory.appendingPathComponent(name)
    }

    /// Basename only; strips directory prefixes. Rejects URLs and `..` traversal.
    public static func sanitizedFilename(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        if path.isEmpty { return nil }
        if path.contains("://") { return nil }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        let name = parts.last!
        guard !name.isEmpty else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        guard imageExtensions.contains(ext) else { return nil }
        return name
    }

    // MARK: - Internals

    static func rawImageDestinations(in markdown: String) -> [String] {
        let pattern = #"!\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^)]+))\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = markdown as NSString
        let full = NSRange(location: 0, length: ns.length)
        var dests: [String] = []
        regex.enumerateMatches(in: markdown, options: [], range: full) { match, _, _ in
            guard let match else { return }
            let destRange = match.range(at: 2).location != NSNotFound
                ? match.range(at: 2)
                : match.range(at: 3)
            guard destRange.location != NSNotFound else { return }
            var dest = ns.substring(with: destRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if dest.hasPrefix("<"), dest.hasSuffix(">") {
                dest = String(dest.dropFirst().dropLast())
            }
            dests.append(dest)
        }
        return dests
    }

    /// Prefer on-disk structured relative path; else basename next to the note.
    public static func resolveExistingImageURL(_ raw: String, noteDirectory: URL) -> URL? {
        guard let name = sanitizedFilename(raw) else { return nil }
        var relative = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if relative.hasPrefix("./") { relative = String(relative.dropFirst(2)) }
        relative = relative.replacingOccurrences(of: "\\", with: "/")
        if relative.contains("..") { return nil }

        if relative != name, !relative.isEmpty {
            let structured = noteDirectory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: structured.path) {
                return structured.standardizedFileURL
            }
        }
        let flat = noteDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: flat.path) {
            return flat.standardizedFileURL
        }
        return nil
    }

    private static func findImageFile(
        basename: String,
        noteDirectory: URL,
        markdown: String?
    ) -> URL? {
        let flat = noteDirectory.appendingPathComponent(basename)
        if FileManager.default.fileExists(atPath: flat.path) {
            return flat
        }
        guard let markdown else { return nil }
        for dest in rawImageDestinations(in: markdown) {
            guard sanitizedFilename(dest) == basename else { continue }
            if let url = resolveExistingImageURL(dest, noteDirectory: noteDirectory) {
                return url
            }
        }
        return nil
    }
}

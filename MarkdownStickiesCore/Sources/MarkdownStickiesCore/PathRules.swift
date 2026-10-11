import Foundation

/// Validation and comparison rules for relative paths inside a root folder.
///
/// Every path that comes from the other device goes through `validate` before use, and
/// through `resolve` before anything is written.
public enum PathRules {
    public enum Kind: Sendable {
        case note
        case image
    }

    public enum Violation: Error, Equatable, Sendable {
        case empty
        case absolute
        case emptyComponent
        case dotComponent
        case parentReference
        case hiddenComponent
        case componentTooLong
        case invalidCharacter
        case wrongExtension
        case escapesRoot
    }

    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp",
    ]

    /// Unicode NFC. Every path is normalized before it is compared, sent or stored.
    public static func normalized(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    /// Key for collision checks: NFC, case-folded. Identity comparisons use `normalized` instead.
    public static func collisionKey(_ path: String) -> String {
        normalized(path).folding(options: [.caseInsensitive], locale: nil)
    }

    /// Checks a relative path and returns it normalized.
    ///
    /// Rejects absolute paths, empty, `.` and `..` components, hidden components
    /// (anything starting with `.`, which covers `.stickies-trash`), NUL characters,
    /// components over 255 bytes, and the wrong file type for `kind`.
    public static func validate(_ path: String, as kind: Kind) -> Result<String, Violation> {
        let path = normalized(path)
        guard !path.isEmpty else { return .failure(.empty) }
        guard !path.hasPrefix("/") else { return .failure(.absolute) }
        guard !path.contains("\0") else { return .failure(.invalidCharacter) }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            if component.isEmpty { return .failure(.emptyComponent) }
            if component == "." { return .failure(.dotComponent) }
            if component == ".." { return .failure(.parentReference) }
            if component.hasPrefix(".") { return .failure(.hiddenComponent) }
            if component.utf8.count > 255 { return .failure(.componentTooLong) }
        }

        let ext = (path as NSString).pathExtension.lowercased()
        switch kind {
        case .note:
            guard ext == "md" else { return .failure(.wrongExtension) }
        case .image:
            guard imageExtensions.contains(ext) else { return .failure(.wrongExtension) }
        }
        return .success(path)
    }

    /// Validates `relativePath` and resolves it inside `root`, following symlinks.
    /// Fails if the result lies outside the root.
    public static func resolve(
        _ relativePath: String,
        as kind: Kind,
        in root: URL
    ) -> Result<URL, Violation> {
        switch validate(relativePath, as: kind) {
        case .failure(let violation):
            return .failure(violation)
        case .success(let path):
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            let candidate = URL(fileURLWithPath: rootPath, isDirectory: true)
                .appendingPathComponent(path)
            let resolved = resolvingExistingSymlinks(candidate).path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard resolved.hasPrefix(prefix) else { return .failure(.escapesRoot) }
            return .success(URL(fileURLWithPath: resolved))
        }
    }

    /// Resolves symlinks in the longest existing prefix of `url`, then re-appends the
    /// components that don't exist yet (a file about to be created).
    private static func resolvingExistingSymlinks(_ url: URL) -> URL {
        var existing = url
        var missing: [String] = []
        let fm = FileManager.default
        while !fm.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missing {
            resolved.appendPathComponent(component)
        }
        return resolved
    }
}

import CryptoKit
import Foundation

/// Content hashes used by sync. Decisions compare these only, never modification times.
public enum NoteHashing {
    /// SHA-256 of the raw file bytes, lowercase hex.
    public static func fileHash(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// SHA-256 of the raw bytes after removing exactly one line: the `stickies-color` line
    /// inside the frontmatter block, including its line terminator. Without such a line,
    /// this equals `fileHash`.
    ///
    /// Comparing `restHash` and color separately tells "text changed" apart from "color changed".
    public static func restHash(_ data: Data) -> String {
        let bytes = [UInt8](data)
        guard let block = StickiesFrontmatter.block(in: bytes),
              let field = block.fields.first(where: { $0.key == StickiesFrontmatter.colorKey })
        else { return fileHash(data) }

        var rest = bytes
        rest.removeSubrange(field.lineStart..<field.lineEnd)
        return fileHash(Data(rest))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

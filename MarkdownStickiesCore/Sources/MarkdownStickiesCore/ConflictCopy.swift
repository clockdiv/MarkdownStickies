import CryptoKit
import Foundation

/// Naming and identity of conflict copies.
public enum ConflictCopy {
    /// Fixed namespace for conflict-copy UUIDs. Never change it: existing copies are found by these ids.
    static let namespace = UUID(uuidString: "6F1C2B4E-3D5A-4E7B-9C8D-0A1B2C3D4E5F")!

    /// Deterministic `stickies-id` for a conflict copy: UUIDv5 of the original's id and the
    /// copied version's file hash. The same conflict always gets the same id, so an
    /// interrupted sync reuses the copy instead of creating a second one.
    public static func id(originalID: UUID, sourceFileHash: String) -> UUID {
        let name = originalID.uuidString.uppercased() + ":" + sourceFileHash.lowercased()
        return uuidV5(namespace: namespace, name: name)
    }

    /// `<stem> (conflict <device> <yyyy-mm-dd>).md` for an original file name like `idea.md`.
    public static func filename(
        forOriginal original: String,
        deviceName: String,
        date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let stem = (original as NSString).deletingPathExtension
        return "\(stem) (conflict \(safeDeviceName(deviceName)) \(day(date, timeZone: timeZone))).md"
    }

    // MARK: - Private

    /// Device names can contain anything; keep the file name valid and not hidden.
    private static func safeDeviceName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "device" : name
    }

    private static func day(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// RFC 4122 version 5 (SHA-1, name-based) UUID.
    private static func uuidV5(namespace: UUID, name: String) -> UUID {
        var input = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        input += Array(name.utf8)
        var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

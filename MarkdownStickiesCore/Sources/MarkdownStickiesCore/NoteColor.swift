import Foundation

/// Sticky color as stored in frontmatter (`stickies-color`): a preset name or `#rrggbb`.
///
/// Platform colors (NSColor / UIColor / SwiftUI) are mapped in each app.
public enum NoteColor: Hashable, Sendable {
    case preset(Preset)
    /// Lowercase `#rrggbb`.
    case custom(String)

    public enum Preset: String, CaseIterable, Sendable {
        case yellow
        case blue
        case green
        case pink
        case purple
        case gray
    }

    public static let `default` = NoteColor.preset(.yellow)

    /// Parses a frontmatter value. Returns `nil` for unknown values; callers show the
    /// default color and leave the value in the file untouched.
    public init?(frontmatterValue raw: String) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let preset = Preset(rawValue: value.lowercased()) {
            self = .preset(preset)
            return
        }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        self = .custom("#" + hex.lowercased())
    }

    public var frontmatterValue: String {
        switch self {
        case .preset(let preset):
            return preset.rawValue
        case .custom(let hex):
            return hex
        }
    }
}

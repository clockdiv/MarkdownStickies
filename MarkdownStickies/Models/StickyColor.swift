import AppKit
import SwiftUI

/// Preset sticky colors (stored by name in note-state.json).
enum StickyColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case yellow
    case blue
    case green
    case pink
    case purple
    case gray

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    var color: Color {
        switch self {
        case .yellow: return Color(red: 1.0, green: 0.95, blue: 0.6)
        case .blue: return Color(red: 0.72, green: 0.88, blue: 1.0)
        case .green: return Color(red: 0.75, green: 0.95, blue: 0.75)
        case .pink: return Color(red: 1.0, green: 0.8, blue: 0.85)
        case .purple: return Color(red: 0.88, green: 0.8, blue: 0.95)
        case .gray: return Color(red: 0.9, green: 0.9, blue: 0.9)
        }
    }

    var nsColor: NSColor {
        NSColor(color)
    }

    /// Stronger tone for list indicators (pastel sticky fills vanish on light gray).
    var listSwatchNSColor: NSColor {
        switch self {
        case .yellow: return NSColor(calibratedRed: 0.78, green: 0.62, blue: 0.05, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.29, green: 0.56, blue: 0.78, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.35, green: 0.62, blue: 0.35, alpha: 1)
        case .pink: return NSColor(calibratedRed: 0.78, green: 0.42, blue: 0.54, alpha: 1)
        case .purple: return NSColor(calibratedRed: 0.55, green: 0.42, blue: 0.69, alpha: 1)
        case .gray: return NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.45, alpha: 1)
        }
    }
}

/// Note background: either a named preset or a custom CSS hex (`#rrggbb`).
enum NoteColor: Equatable, Codable, Sendable {
    case preset(StickyColor)
    case custom(String)

    static let `default`: NoteColor = .preset(.yellow)

    var nsColor: NSColor {
        switch self {
        case .preset(let preset):
            return preset.nsColor
        case .custom(let hex):
            return NSColor(hexString: hex) ?? StickyColor.yellow.nsColor
        }
    }

    /// High-contrast color for list swatches (not the pastel sticky fill).
    var listSwatchNSColor: NSColor {
        switch self {
        case .preset(let preset):
            return preset.listSwatchNSColor
        case .custom:
            return nsColor.listSwatchDerived
        }
    }

    var cssHex: String {
        switch self {
        case .preset(let preset):
            return preset.nsColor.reliableHexString
        case .custom(let hex):
            return NoteColor.normalizeHex(hex) ?? presetFallbackHex
        }
    }

    private var presetFallbackHex: String {
        StickyColor.yellow.nsColor.reliableHexString
    }

    var selectedPreset: StickyColor? {
        if case .preset(let p) = self { return p }
        return nil
    }

    init(nsColor: NSColor) {
        let hex = nsColor.reliableHexString
        if let match = StickyColor.allCases.first(where: {
            $0.nsColor.reliableHexString.caseInsensitiveCompare(hex) == .orderedSame
        }) {
            self = .preset(match)
        } else {
            self = .custom(hex)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let preset = StickyColor(rawValue: raw) {
            self = .preset(preset)
        } else if let hex = NoteColor.normalizeHex(raw) {
            self = .custom(hex)
        } else {
            self = .default
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .preset(let preset):
            try container.encode(preset.rawValue)
        case .custom(let hex):
            try container.encode(NoteColor.normalizeHex(hex) ?? hex)
        }
    }

    static func normalizeHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, s.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + s.lowercased()
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        guard let normalized = NoteColor.normalizeHex(hexString) else { return nil }
        let hex = String(normalized.dropFirst())
        guard let value = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(calibratedRed: r, green: g, blue: b, alpha: 1)
    }

    /// Darken / punch up a pastel so it reads on a light-gray canvas.
    var listSwatchDerived: NSColor {
        let rgb = usingColorSpace(.deviceRGB) ?? usingColorSpace(.sRGB) ?? self
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let newS = min(1, max(s, 0.55) * 1.15)
        let newB = min(0.72, max(0.35, b * 0.65))
        return NSColor(calibratedHue: h, saturation: newS, brightness: newB, alpha: 1)
    }
}

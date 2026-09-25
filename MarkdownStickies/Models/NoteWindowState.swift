import Foundation

struct NoteWindowState: Codable, Equatable, Sendable {
    var frame: CGRectCodable
    var color: NoteColor
    var isOpen: Bool
    var floatOnTop: Bool
    /// Base body text size in points (HTML/CSS).
    var textSize: Double
    /// Newspaper-style CSS columns (1…8). Not stored in markdown.
    var columnCount: Int
    /// When the sticky was last opened — drives list order (not file mtime).
    var lastOpenedAt: Date?

    static let defaultTextSize: Double = 11
    static let minTextSize: Double = 6
    static let maxTextSize: Double = 28

    static let defaultColumnCount: Int = 1
    static let minColumnCount: Int = 1
    static let maxColumnCount: Int = 8

    static func `default`(color: NoteColor = .default) -> NoteWindowState {
        NoteWindowState(
            frame: CGRectCodable(x: 120, y: 120, width: 280, height: 280),
            color: color,
            isOpen: false,
            floatOnTop: false,
            textSize: defaultTextSize,
            columnCount: defaultColumnCount,
            lastOpenedAt: nil
        )
    }

    enum CodingKeys: String, CodingKey {
        case frame, color, isOpen, floatOnTop, textSize, columnCount, lastOpenedAt
    }

    init(
        frame: CGRectCodable,
        color: NoteColor,
        isOpen: Bool,
        floatOnTop: Bool,
        textSize: Double = Self.defaultTextSize,
        columnCount: Int = Self.defaultColumnCount,
        lastOpenedAt: Date? = nil
    ) {
        self.frame = frame
        self.color = color
        self.isOpen = isOpen
        self.floatOnTop = floatOnTop
        self.textSize = textSize
        self.columnCount = Self.clampedColumnCount(columnCount)
        self.lastOpenedAt = lastOpenedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(CGRectCodable.self, forKey: .frame)
        // Backward compatible: old files stored StickyColor names as strings.
        if let noteColor = try? c.decode(NoteColor.self, forKey: .color) {
            color = noteColor
        } else if let legacy = try? c.decode(StickyColor.self, forKey: .color) {
            color = .preset(legacy)
        } else {
            color = .default
        }
        isOpen = try c.decode(Bool.self, forKey: .isOpen)
        floatOnTop = try c.decode(Bool.self, forKey: .floatOnTop)
        textSize = try c.decodeIfPresent(Double.self, forKey: .textSize) ?? Self.defaultTextSize
        columnCount = Self.clampedColumnCount(
            try c.decodeIfPresent(Int.self, forKey: .columnCount) ?? Self.defaultColumnCount
        )
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
    }

    static func clampedColumnCount(_ value: Int) -> Int {
        min(maxColumnCount, max(minColumnCount, value))
    }
}

struct CGRectCodable: Codable, Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }
}

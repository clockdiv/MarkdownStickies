import Foundation

struct NoteWindowState: Codable, Equatable, Sendable {
    var frame: CGRectCodable
    /// Color from before it moved into the note's frontmatter (`stickies-color`). Read once,
    /// written into the note on its next open, then cleared. Never set otherwise.
    var legacyColor: NoteColor?
    /// Legacy field — open stickies are tracked per set in `NoteStateFile.setOpenPaths`.
    var isOpen: Bool
    var floatOnTop: Bool
    /// Base body text size in points (HTML/CSS).
    var textSize: Double
    /// Newspaper-style CSS columns (1…8). Not stored in markdown.
    var columnCount: Int
    /// When the sticky was last opened — drives list order (not file mtime).
    var lastOpenedAt: Date?
    /// Set by “Remove from Recents”; sorts the note to the bottom until opened again.
    var removedFromRecentsAt: Date?
    /// Legacy exclusive-set field; migrated into `setOpenPaths` on load.
    var setIndex: Int

    static let defaultTextSize: Double = 11
    static let minTextSize: Double = 6
    static let maxTextSize: Double = 28

    static let defaultColumnCount: Int = 1
    static let minColumnCount: Int = 1
    static let maxColumnCount: Int = 8

    static let setCount: Int = 10
    static let minSetIndex: Int = 0
    static let maxSetIndex: Int = 9

    static func `default`() -> NoteWindowState {
        NoteWindowState(
            frame: CGRectCodable(x: 120, y: 120, width: 280, height: 280),
            isOpen: false,
            floatOnTop: false,
            textSize: defaultTextSize,
            columnCount: defaultColumnCount,
            lastOpenedAt: nil,
            removedFromRecentsAt: nil,
            setIndex: 0
        )
    }

    enum CodingKeys: String, CodingKey {
        case frame, isOpen, floatOnTop, textSize, columnCount, lastOpenedAt, removedFromRecentsAt, setIndex
        case legacyColor = "color"
    }

    init(
        frame: CGRectCodable,
        legacyColor: NoteColor? = nil,
        isOpen: Bool,
        floatOnTop: Bool,
        textSize: Double = Self.defaultTextSize,
        columnCount: Int = Self.defaultColumnCount,
        lastOpenedAt: Date? = nil,
        removedFromRecentsAt: Date? = nil,
        setIndex: Int = 0
    ) {
        self.frame = frame
        self.legacyColor = legacyColor
        self.isOpen = isOpen
        self.floatOnTop = floatOnTop
        self.textSize = textSize
        self.columnCount = Self.clampedColumnCount(columnCount)
        self.lastOpenedAt = lastOpenedAt
        self.removedFromRecentsAt = removedFromRecentsAt
        self.setIndex = Self.clampedSetIndex(setIndex)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(CGRectCodable.self, forKey: .frame)
        // Backward compatible: old files stored StickyColor names as strings.
        if let noteColor = try? c.decode(NoteColor.self, forKey: .legacyColor) {
            legacyColor = noteColor
        } else if let legacy = try? c.decode(StickyColor.self, forKey: .legacyColor) {
            legacyColor = .preset(legacy)
        } else {
            legacyColor = nil
        }
        isOpen = try c.decode(Bool.self, forKey: .isOpen)
        floatOnTop = try c.decode(Bool.self, forKey: .floatOnTop)
        textSize = try c.decodeIfPresent(Double.self, forKey: .textSize) ?? Self.defaultTextSize
        columnCount = Self.clampedColumnCount(
            try c.decodeIfPresent(Int.self, forKey: .columnCount) ?? Self.defaultColumnCount
        )
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        removedFromRecentsAt = try c.decodeIfPresent(Date.self, forKey: .removedFromRecentsAt)
        setIndex = Self.clampedSetIndex(try c.decodeIfPresent(Int.self, forKey: .setIndex) ?? 0)
    }

    static func clampedColumnCount(_ value: Int) -> Int {
        min(maxColumnCount, max(minColumnCount, value))
    }

    static func clampedSetIndex(_ value: Int) -> Int {
        min(maxSetIndex, max(minSetIndex, value))
    }

    static func setKey(_ index: Int) -> String {
        String(clampedSetIndex(index))
    }
}

/// On-disk shape for `~/.markdown-stickies/note-state.json`.
/// Sets are open-layouts: each set remembers which notes were open (not note ownership).
struct NoteStateFile: Codable, Equatable, Sendable {
    var activeSet: Int
    var notes: [String: NoteWindowState]
    /// Keys `"0"`…`"9"` → paths open in that set.
    var setOpenPaths: [String: [String]]

    enum CodingKeys: String, CodingKey {
        case activeSet, notes, setOpenPaths
    }

    init(
        activeSet: Int = 0,
        notes: [String: NoteWindowState] = [:],
        setOpenPaths: [String: [String]] = [:]
    ) {
        self.activeSet = NoteWindowState.clampedSetIndex(activeSet)
        self.notes = notes
        self.setOpenPaths = setOpenPaths
    }

    init(from decoder: Decoder) throws {
        enum Probe: String, CodingKey { case activeSet, notes, setOpenPaths }
        if let c = try? decoder.container(keyedBy: Probe.self), c.contains(.notes) {
            activeSet = NoteWindowState.clampedSetIndex(try c.decodeIfPresent(Int.self, forKey: .activeSet) ?? 0)
            notes = try c.decodeIfPresent([String: NoteWindowState].self, forKey: .notes) ?? [:]
            setOpenPaths = try c.decodeIfPresent([String: [String]].self, forKey: .setOpenPaths) ?? [:]
            // Migrate exclusive-set era: open notes lived on the note via isOpen + setIndex.
            if setOpenPaths.isEmpty {
                var migrated: [String: [String]] = [:]
                for (path, state) in notes where state.isOpen {
                    let key = NoteWindowState.setKey(state.setIndex)
                    migrated[key, default: []].append(path)
                }
                setOpenPaths = migrated
            }
            return
        }
        // Legacy: bare `{ "path": NoteWindowState, ... }`
        let legacy = try [String: NoteWindowState](from: decoder)
        activeSet = 0
        notes = legacy
        var migrated: [String: [String]] = [:]
        for (path, state) in legacy where state.isOpen {
            migrated[NoteWindowState.setKey(0), default: []].append(path)
        }
        setOpenPaths = migrated
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

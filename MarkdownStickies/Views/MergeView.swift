import MarkdownStickiesCore
import SwiftUI

/// A conflict copy and the note it belongs to, as loaded when the merge view opened.
struct MergeRequest: Identifiable {
    var id: String { copy.path.path }
    let original: Note
    let copy: Note
    let originalData: Data
    let copyData: Data
    /// The common base both versions started from (from the sync state), if known.
    let baseData: Data?

    var originalBody: String { NoteFrontmatter.splitDocument(String(decoding: originalData, as: UTF8.self)).body }
    var copyBody: String { NoteFrontmatter.splitDocument(String(decoding: copyData, as: UTF8.self)).body }
    var baseBody: String? {
        baseData.map { NoteFrontmatter.splitDocument(String(decoding: $0, as: UTF8.self)).body }
    }

    /// Device that made the copy, from `<stem> (conflict <device> <date>).md`.
    var copyDeviceName: String {
        let name = copy.path.deletingPathExtension().lastPathComponent
        guard let open = name.range(of: " (conflict ", options: .backwards),
              let close = name.range(of: ")", options: .backwards), open.upperBound < close.lowerBound
        else { return "the other device" }
        let inner = name[open.upperBound..<close.lowerBound]
        let parts = inner.split(separator: " ")
        guard parts.count > 1 else { return String(inner) }
        return parts.dropLast().joined(separator: " ")   // drop the date
    }
}

/// One line in the merge view. Changed lines can be kept (+) or dropped (−).
private struct MergeLine: Identifiable {
    enum Side { case common, mine, theirs }

    let id: Int
    let text: String
    let side: Side
    /// True for lines the other side or both sides removed (shown struck through when dropped).
    let isRemoval: Bool
    /// Part of lines both devices changed differently.
    let isConflict: Bool
    /// First line of a conflict group (shows the "changed on both" header).
    let startsConflict: Bool
    var included: Bool
    var isToggleable: Bool { side != .common || isRemoval }
}

/// Three-way merge of a conflict copy into its original (spec §4), as in git: both versions are
/// compared to their common base. Changes made on one device are pre-selected; lines both
/// devices changed are marked as a conflict. Every changed line has + (keep) and − (drop).
/// Saving writes the result into the original (keeping its frontmatter) and moves the copy
/// to the Trash.
struct MergeView: View {
    let request: MergeRequest
    var onSave: (String) -> String?
    var onCancel: () -> Void

    @State private var lines: [MergeLine]
    @State private var manualResult: String?
    @State private var error: String?

    private static let macColor = Color(red: 0.20, green: 0.45, blue: 0.85)
    private static let deviceColor = Color(red: 0.90, green: 0.50, blue: 0.10)

    init(request: MergeRequest, onSave: @escaping (String) -> String?, onCancel: @escaping () -> Void) {
        self.request = request
        self.onSave = onSave
        self.onCancel = onCancel
        _lines = State(initialValue: Self.makeLines(TextMerge3.merge(
            base: request.baseBody,
            mine: request.originalBody,
            theirs: request.copyBody
        )))
    }

    private var selectedResult: String {
        lines.filter(\.included).map(\.text).joined(separator: "\n")
    }

    private var conflictCount: Int {
        lines.filter(\.startsConflict).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge “\(request.original.title)”")
                .font(.system(size: 17, weight: .semibold))

            HStack(spacing: 14) {
                legend(Self.macColor, "This Mac")
                legend(Self.deviceColor, request.copyDeviceName)
                Spacer()
                Text(request.baseData == nil
                     ? "No common version stored: every difference is shown as a conflict."
                     : (conflictCount == 0 ? "No conflicts: all changes merged." : "\(conflictCount) conflict\(conflictCount == 1 ? "" : "s") to check"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Text("Changes from one device are already taken. Use + to keep a line and − to drop it. Lines a device deleted are struck through; + brings them back.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach($lines) { $line in
                        if line.startsConflict {
                            Text("Changed on both devices")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6)
                                .padding(.top, 6)
                        }
                        row($line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .disabled(manualResult != nil)
            .opacity(manualResult != nil ? 0.5 : 1)

            HStack(spacing: 8) {
                Button("Conflicts: Keep This Mac") { resolveConflicts(keep: .mine) }
                Button("Conflicts: Keep \(request.copyDeviceName)") { resolveConflicts(keep: .theirs) }
                Spacer()
                if manualResult != nil {
                    Button("Discard Manual Edits") { manualResult = nil }
                }
            }
            .disabled(conflictCount == 0 && manualResult == nil)

            Text(manualResult == nil ? "Result (you can still edit it)" : "Result (edited by hand; the line selection above is paused)")
                .font(.system(size: 13, weight: .semibold))
            TextEditor(text: Binding(
                get: { manualResult ?? selectedResult },
                set: { manualResult = $0 }
            ))
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 140)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Text("Saving updates “\(request.original.title)” and moves the copy to the Trash.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Later", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save Merge") {
                    error = onSave(manualResult ?? selectedResult)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 640)
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 12)
            Text(label).font(.system(size: 12, weight: .medium))
        }
    }

    private func row(_ line: Binding<MergeLine>) -> some View {
        let value = line.wrappedValue
        let color: Color = value.side == .mine ? Self.macColor : (value.side == .theirs ? Self.deviceColor : .clear)
        return HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 3)
            if value.isToggleable {
                Button { line.wrappedValue.included = true } label: {
                    Image(systemName: "plus.circle\(value.included ? ".fill" : "")")
                }
                .buttonStyle(.plain)
                .foregroundStyle(value.included ? color : .secondary)
                .help("Keep this line")
                Button { line.wrappedValue.included = false } label: {
                    Image(systemName: "minus.circle\(value.included ? "" : ".fill")")
                }
                .buttonStyle(.plain)
                .foregroundStyle(value.included ? .secondary : color)
                .help("Drop this line")
            } else {
                Color.clear.frame(width: 38, height: 1)
            }
            Text(value.text.isEmpty ? " " : value.text)
                .font(.system(size: 12, design: .monospaced))
                .strikethrough(!value.included)
                .foregroundStyle(value.included ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.trailing, 6)
        .padding(.vertical, 1)
        .background(color.opacity(value.included ? 0.12 : 0.04))
        .overlay(alignment: .leading) {
            if value.isConflict { Rectangle().fill(Color.red.opacity(0.6)).frame(width: 2).offset(x: -3) }
        }
    }

    private func resolveConflicts(keep side: MergeLine.Side) {
        manualResult = nil
        for index in lines.indices where lines[index].isConflict {
            if lines[index].isRemoval {
                lines[index].included = false
            } else {
                lines[index].included = lines[index].side == side
            }
        }
    }

    private static func makeLines(_ hunks: [TextMerge3.Hunk]) -> [MergeLine] {
        var result: [MergeLine] = []
        func add(_ text: String, _ side: MergeLine.Side, removal: Bool = false, conflict: Bool = false, first: Bool = false, included: Bool) {
            result.append(MergeLine(
                id: result.count,
                text: text,
                side: side,
                isRemoval: removal,
                isConflict: conflict,
                startsConflict: first,
                included: included
            ))
        }
        for hunk in hunks {
            switch hunk {
            case .unchanged(let lines):
                lines.forEach { add($0, .common, included: true) }
            case .both(_, let lines):
                lines.forEach { add($0, .common, included: true) }
            case .onlyMine(let base, let mine):
                base.forEach { add($0, .mine, removal: true, included: false) }
                mine.forEach { add($0, .mine, included: true) }
            case .onlyTheirs(let base, let theirs):
                base.forEach { add($0, .theirs, removal: true, included: false) }
                theirs.forEach { add($0, .theirs, included: true) }
            case .conflict(let base, let mine, let theirs):
                var first = true
                for line in base {
                    add(line, .common, removal: true, conflict: true, first: first, included: false)
                    first = false
                }
                for line in mine {
                    add(line, .mine, conflict: true, first: first, included: true)
                    first = false
                }
                for line in theirs {
                    add(line, .theirs, conflict: true, first: first, included: true)
                    first = false
                }
            }
        }
        return result
    }
}

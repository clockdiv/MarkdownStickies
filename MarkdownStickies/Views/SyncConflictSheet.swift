import MarkdownStickiesCore
import SwiftUI

/// Post-sync conflict review: colored per-device diff with +/- line picks into the original note.
struct SyncConflictSheet: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss

    @State private var selected: SyncConflict?
    @State private var mode: Mode = .review
    @State private var mergeText = ""
    /// Per divergent line: `true` = keep, `false` = drop. Missing = undecided (must choose).
    @State private var lineChoices: [Int: Bool] = [:]

    private enum Mode {
        case list
        case review
        case edit
    }

    /// This Mac — cool blue.
    private static let localTint = Color(red: 0.22, green: 0.48, blue: 0.78)
    /// Peer device — warm amber.
    private static let peerTint = Color(red: 0.82, green: 0.52, blue: 0.14)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch mode {
            case .list:
                conflictList
            case .review:
                if let selected {
                    reviewPane(selected)
                }
            case .edit:
                editPane
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 440, idealHeight: 560)
        .onAppear {
            if selected == nil {
                selected = store.pendingConflicts.first
            }
            mode = store.pendingConflicts.count <= 1 ? .review : .list
            lineChoices = [:]
        }
        .onChange(of: store.pendingConflicts.count) { _, count in
            if count == 0 {
                dismiss()
            } else if selected == nil || !store.pendingConflicts.contains(where: { $0.id == selected?.id }) {
                selected = store.pendingConflicts.first
                mode = count <= 1 ? .review : .list
                lineChoices = [:]
            }
        }
        .onChange(of: selected?.id) { _, _ in
            lineChoices = [:]
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.pendingConflicts.count == 1 ? "Sync conflict" : "Sync conflicts")
                    .font(.system(size: 18, weight: .bold))
                Text("Tap +/− on each colored line, or the device chips to take one side. Sync Later aborts on both devices.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Sync Later") {
                store.dismissPendingConflicts()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .help("Cancel merge on Mac and iPhone — note bodies stay unchanged")
        }
        .padding(16)
    }

    private var conflictList: some View {
        List(selection: Binding(
            get: { selected?.id },
            set: { id in
                selected = store.pendingConflicts.first { $0.id == id }
                if selected != nil { mode = .review }
            }
        )) {
            ForEach(store.pendingConflicts) { conflict in
                VStack(alignment: .leading, spacing: 4) {
                    Text(conflict.local.title)
                        .font(.system(size: 14, weight: .semibold))
                    Text("This Mac · \(conflict.peerLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .tag(conflict.id)
            }
        }
        .listStyle(.inset)
    }

    private func reviewPane(_ conflict: SyncConflict) -> some View {
        let lines = diffLines(for: conflict)
        return VStack(alignment: .leading, spacing: 0) {
            if store.pendingConflicts.count > 1 {
                Button {
                    mode = .list
                } label: {
                    Label("All conflicts", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            legend(conflict: conflict, lines: lines)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Text(conflict.local.title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                        diffLine(line, offset: offset)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            resolveBar(conflict, lines: lines)
        }
    }

    private func legend(conflict: SyncConflict, lines: [TextDiff.Line]) -> some View {
        let macName = displayDeviceName(store.syncService.deviceName)
        let peerName = displayDeviceName(conflict.peerLabel)
        return HStack(alignment: .center, spacing: 12) {
            Button {
                selectAll(from: .mac, lines: lines)
            } label: {
                legendChip(swatch: .solid(Self.localTint), label: macName)
            }
            .buttonStyle(.plain)
            .help("Keep every \(macName) line; drop every \(peerName) line")

            Button {
                selectSafeBoth(conflict: conflict, lines: lines)
            } label: {
                legendChip(swatch: .mix(Self.localTint, Self.peerTint), label: "Both")
            }
            .buttonStyle(.plain)
            .help("Keep non-overlapping edits from \(macName) and \(peerName); opens an editor if the same lines clash")

            Button {
                selectAll(from: .peer, lines: lines)
            } label: {
                legendChip(swatch: .solid(Self.peerTint), label: peerName)
            }
            .buttonStyle(.plain)
            .help("Keep every \(peerName) line; drop every \(macName) line")

            Spacer(minLength: 0)
        }
    }

    private enum ChipSwatch {
        case solid(Color)
        case mix(Color, Color)
    }

    private func legendChip(swatch: ChipSwatch, label: String) -> some View {
        let fill: Color = {
            switch swatch {
            case .solid(let c): return c.opacity(0.08)
            case .mix: return Color.primary.opacity(0.04)
            }
        }()
        let border: Color = {
            switch swatch {
            case .solid(let c): return c.opacity(0.35)
            case .mix(let a, _): return a.opacity(0.4)
            }
        }()

        // Fixed height so Mac / Both / peer stay aligned whether the name wraps or not.
        return HStack(alignment: .center, spacing: 8) {
            swatchView(swatch)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: 128, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 112, minHeight: 44, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func swatchView(_ swatch: ChipSwatch) -> some View {
        switch swatch {
        case .solid(let color):
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(color.opacity(0.7), lineWidth: 1)
                )
                .frame(width: 14, height: 14)
        case .mix(let left, let right):
            HStack(spacing: 0) {
                left.opacity(0.55)
                right.opacity(0.55)
            }
            .frame(width: 14, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private enum Side { case mac, peer }

    private func selectAll(from side: Side, lines: [TextDiff.Line]) {
        var next = lineChoices
        for (offset, line) in lines.enumerated() {
            switch line {
            case .same:
                continue
            case .removed:
                next[offset] = (side == .mac)
            case .added:
                next[offset] = (side == .peer)
            }
        }
        lineChoices = next
    }

    /// Preset: + every divergent line when TextMerge can combine safely; else marker editor.
    private func selectSafeBoth(conflict: SyncConflict, lines: [TextDiff.Line]) {
        let result = TextMerge.mergeDocuments(
            localMarkdown: conflict.local.body,
            remoteMarkdown: conflict.remote.body,
            keepingID: conflict.id,
            localLabel: "This Mac",
            remoteLabel: conflict.peerLabel
        )
        if result.hasConflicts {
            mergeText = result.body
            mode = .edit
            return
        }
        var next: [Int: Bool] = [:]
        for (offset, line) in lines.enumerated() where !lineIsSame(line) {
            next[offset] = true
        }
        lineChoices = next
    }

    /// Full device name for chips — wrap in the UI instead of truncating with “…”.
    private func displayDeviceName(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "peer" : trimmed
    }

    private func diffLine(_ line: TextDiff.Line, offset: Int) -> some View {
        let text = lineText(line)
        let choice = lineChoices[offset]
        let isSame = lineIsSame(line)
        let kept = choice == true
        let dropped = choice == false
        let undecided = !isSame && choice == nil

        return HStack(alignment: .top, spacing: 6) {
            if isSame {
                Color.clear
                    .frame(width: 44, height: 18)
            } else {
                HStack(spacing: 2) {
                    Button {
                        lineChoices[offset] = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(kept ? Color.primary : Color.secondary.opacity(undecided ? 0.35 : 0.45))
                    .help("Keep this line")

                    Button {
                        lineChoices[offset] = false
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(dropped ? Color.primary : Color.secondary.opacity(undecided ? 0.35 : 0.45))
                    .help("Drop this line")
                }
                .frame(width: 44, alignment: .leading)
            }

            Text(text.isEmpty ? " " : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(
                    Color.primary.opacity(
                        isSame ? 0.7 : (undecided ? 0.55 : (kept ? 0.95 : 0.35))
                    )
                )
                .strikethrough(dropped, color: .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(lineBackground(line, choice: choice))
        .opacity(dropped ? 0.85 : 1)
    }

    private func lineText(_ line: TextDiff.Line) -> String {
        switch line {
        case .same(let s), .removed(let s), .added(let s):
            return s
        }
    }

    private func lineIsSame(_ line: TextDiff.Line) -> Bool {
        if case .same = line { return true }
        return false
    }

    private func lineBackground(_ line: TextDiff.Line, choice: Bool?) -> Color {
        let active = choice != false
        switch line {
        case .same:
            return .clear
        case .removed:
            return Self.localTint.opacity(choice == nil ? 0.07 : (active ? 0.12 : 0.04))
        case .added:
            return Self.peerTint.opacity(choice == nil ? 0.08 : (active ? 0.14 : 0.04))
        }
    }

    private func resolveBar(_ conflict: SyncConflict, lines: [TextDiff.Line]) -> some View {
        let divergent = lines.enumerated().filter { !lineIsSame($0.element) }
        let undecided = divergent.filter { lineChoices[$0.offset] == nil }.count
        let ready = undecided == 0

        return VStack(alignment: .leading, spacing: 10) {
            Text(ready
                 ? "All lines decided. Apply writes into the original note."
                 : "Decide \(undecided) remaining line\(undecided == 1 ? "" : "s") (+/− or Mac / Both / peer chips).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Apply selection") {
                    applyLineSelection(conflict, lines: lines)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ready)

                Spacer()

                Button("Keep both files") {
                    store.openConflictNotes(conflict)
                    store.acknowledgeConflict(conflict)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
    }

    private var editPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    mode = .review
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Edit original note")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Save into original") {
                    guard let selected else { return }
                    store.mergeConflict(selected, mergedBody: mergeText)
                }
                .buttonStyle(.borderedProminent)
                .disabled(mergeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)

            if let selected {
                Text(editHint(for: selected))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            TextEditor(text: $mergeText)
                .font(.system(size: 13, design: .monospaced))
                .padding(8)
        }
    }

    private func diffLines(for conflict: SyncConflict) -> [TextDiff.Line] {
        TextDiff.unified(
            local: displayBody(conflict.local.body),
            remote: displayBody(conflict.remote.body)
        )
    }

    private func applyLineSelection(_ conflict: SyncConflict, lines: [TextDiff.Line]) {
        let kept = lines.enumerated().compactMap { offset, line -> String? in
            if lineIsSame(line) { return lineText(line) }
            guard lineChoices[offset] == true else { return nil }
            return lineText(line)
        }
        let body = kept.isEmpty ? "\n" : kept.joined(separator: "\n") + "\n"
        let parts = NoteFrontmatter.splitDocument(conflict.local.body)
        let doc = NoteFrontmatter.joinDocument(prefix: parts.prefix, body: body)
        store.mergeConflict(conflict, mergedBody: doc)
    }

    private func editHint(for conflict: SyncConflict) -> String {
        if mergeText.contains("<<<<<<<") {
            return "Conflict markers left where both changed the same lines. Keep one side, delete markers, then Save. Peer copy (\(conflict.peerLabel)) is discarded."
        }
        return "Saves into “\(conflict.local.title)”. Peer copy (\(conflict.peerLabel)) is discarded."
    }

    /// Body without frontmatter so the diff reads like the note, not metadata noise.
    private func displayBody(_ markdown: String) -> String {
        NoteFrontmatter.splitDocument(markdown).body
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }
}

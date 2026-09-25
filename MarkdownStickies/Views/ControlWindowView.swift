import SwiftUI
import AppKit

struct ControlWindowView: View {
    @EnvironmentObject private var store: NoteStore
    @State private var selectedTab: ControlTab = .notes

    /// Soft off-white canvas (mockup: airy, not dense gray slabs).
    private static let canvas = Color(nsColor: NSColor(calibratedWhite: 0.96, alpha: 1))
    private static let iconColor = Color(nsColor: NSColor(calibratedWhite: 0.35, alpha: 1))

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            switch selectedTab {
            case .notes:
                notesPane
            case .settings:
                settingsPane
            }
        }
        .frame(minWidth: 340, idealWidth: 380, minHeight: 460, idealHeight: 520)
        .background(Self.canvas)
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(selectedTab == .notes ? "Notes" : "Settings")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color(nsColor: NSColor(calibratedWhite: 0.12, alpha: 1)))

            Spacer(minLength: 0)

            Button {
                store.promptCreateNote()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Self.iconColor)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New note")
            .onHover { setHandCursor($0) }

            Button {
                selectedTab = selectedTab == .notes ? .settings : .notes
            } label: {
                Image(systemName: selectedTab == .settings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Self.iconColor)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(selectedTab == .settings ? "Back to Notes" : "Settings")
            .onHover { setHandCursor($0) }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.tertiary)

            TextField("Search notes", text: $store.filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onKeyPress(.escape) {
                    guard !store.filterText.isEmpty else { return .ignored }
                    store.filterText = ""
                    return .handled
                }

            if !store.filterText.isEmpty {
                Button {
                    store.filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var notesPane: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 18)
                .padding(.bottom, 4)

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            if store.bookmarks.roots.isEmpty {
                ContentUnavailableView(
                    "No Scan Folders",
                    systemImage: "folder.badge.plus",
                    description: Text("Add folders in Settings to find .md notes next to your projects.")
                )
            } else if store.filteredNotes.isEmpty {
                ContentUnavailableView(
                    store.notes.isEmpty ? "No Notes Found" : "No Matches",
                    systemImage: "note.text",
                    description: Text(
                        store.notes.isEmpty
                            ? "Create a note or add a .md file into a scanned folder."
                            : "Try a different search."
                    )
                )
            } else {
                let scanRoots = store.bookmarks.effectiveScanURLs()
                let openPaths = store.windowManager.openPaths
                let activePath = store.windowManager.activePath
                List(store.filteredNotes) { note in
                    NoteListRow(
                        note: note,
                        isOpen: openPaths.contains(note.path.path),
                        isActive: activePath == note.path.path,
                        noteColor: store.stateStore.storedState(for: note.path)?.color,
                        scanRoots: scanRoots,
                        onOpen: { store.openNote(note) }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .id(store.filterText)
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // SwiftUI’s default min row height (~40+) blocks “smaller” paddings.
                .environment(\.defaultMinListRowHeight, 22)
            }
        }
        .background(Self.canvas)
    }

    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan Folders")
                .font(.headline)

            Text("Add folders to scan for .md files. Only these folders are watched.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.bookmarks.roots.isEmpty {
                Text("No folders added yet.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(store.bookmarks.roots) { root in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(root.path.lastPathComponent)
                                    .font(.body.weight(.medium))
                                Text(root.path.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                store.removeScanFolder(root)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(minHeight: 160)
            }

            HStack {
                Button("Add Folder…") {
                    store.addScanFolder()
                }
                Spacer()
                Button("Rescan Now") {
                    store.rescan(restoreWindows: false)
                }
            }

            Divider().opacity(0.35)

            Text("Search (debug)")
                .font(.headline)
            Text("Fuzzy minimum score — higher is stricter.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Slider(value: $store.fuzzyMinimumScore, in: 0...500, step: 1)
                Text("\(Int(store.fuzzyMinimumScore.rounded()))")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            Divider().opacity(0.35)

            Spacer()
        }
        .padding(20)
    }

    private func setHandCursor(_ hovering: Bool) {
        if hovering { NSCursor.pointingHand.set() }
        else { NSCursor.arrow.set() }
    }
}

private struct NoteListRow: View {
    let note: Note
    let isOpen: Bool
    /// Key / focused sticky — title rendered black.
    let isActive: Bool
    /// Color from note-state when present (open or previously configured).
    let noteColor: NoteColor?
    let scanRoots: [URL]
    let onOpen: () -> Void

    @State private var isHovered = false

    private static let titleColor = Color(nsColor: NSColor(calibratedWhite: 0.28, alpha: 1))
    private static let titleHoverColor = Color(nsColor: NSColor(calibratedWhite: 0.08, alpha: 1))
    private static let titleActiveColor = Color.black
    private static let pathRootColor = Color(nsColor: NSColor(calibratedWhite: 0.42, alpha: 1))
    private static let pathRestColor = Color(nsColor: NSColor(calibratedWhite: 0.55, alpha: 1))
    private static let swatchSize: CGFloat = 10

    private var titleForeground: Color {
        if isActive { return Self.titleActiveColor }
        if isHovered { return Self.titleHoverColor }
        return Self.titleColor
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                colorSwatch
                    .frame(width: Self.swatchSize, height: Self.swatchSize)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title)
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(titleForeground)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    locationLine
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(isHovered ? 1 : 0)
                        .accessibilityHidden(!isHovered)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.white : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))
        .onHover { hovering in
            guard isHovered != hovering else { return }
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() }
            else { NSCursor.arrow.set() }
        }
    }

    @ViewBuilder
    private var colorSwatch: some View {
        let shape = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
        if let noteColor {
            let swatch = Color(nsColor: noteColor.listSwatchNSColor)
            if isOpen {
                shape.fill(swatch)
                    .help("Open")
            } else {
                shape.strokeBorder(swatch, lineWidth: 1.75)
                    .help("Saved color")
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var locationLine: some View {
        let parts = Note.locationParts(for: note.path, scanRoots: scanRoots)
        if let subpath = parts.subpath {
            (Text(parts.root).foregroundStyle(Self.pathRootColor)
                + Text("/").foregroundStyle(Self.pathRestColor)
                + Text(subpath).foregroundStyle(Self.pathRestColor))
        } else {
            Text(parts.root).foregroundStyle(Self.pathRootColor)
        }
    }
}

private enum ControlTab {
    case notes
    case settings
}

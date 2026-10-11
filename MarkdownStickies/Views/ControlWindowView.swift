import AppKit
import MarkdownStickiesCore
import SwiftUI

struct ControlWindowView: View {
    @EnvironmentObject private var store: NoteStore
    @State private var selectedTab: ControlTab = .notes
    @State private var showScannedFolders = true
    @State private var showIgnoredFolders = false

    /// Soft off-white canvas (mockup: airy, not dense gray slabs).
    private static let canvas = Color(nsColor: NSColor(calibratedWhite: 0.96, alpha: 1))
    private static let iconColor = Color(nsColor: NSColor(calibratedWhite: 0.35, alpha: 1))

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            switch selectedTab {
            case .notes:
                notesPane
                    .onChange(of: store.filterText) { _, _ in
                        NoteHoverPreviewPanel.hide()
                    }
            case .settings:
                settingsPane
                    .onAppear { NoteHoverPreviewPanel.hide() }
            }
        }
        .frame(minWidth: 340, idealWidth: 380, minHeight: 460, idealHeight: 520)
        .background(Self.canvas)
        .sheet(item: $store.mergeRequest) { request in
            MergeView(
                request: request,
                onSave: { store.saveMerge(request, body: $0) },
                onCancel: { store.finishMerge() }
            )
        }
        .overlay {
            if store.sync.state != .idle {
                SyncBannerOverlay(
                    state: store.sync.state,
                    onCancel: { store.cancelSync() },
                    onDismiss: { store.dismissSyncResult() }
                )
            }
        }
        .onDisappear { NoteHoverPreviewPanel.hide() }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(selectedTab == .notes ? "Notes" : "Settings")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color(nsColor: NSColor(calibratedWhite: 0.12, alpha: 1)))

            Spacer(minLength: 0)

            if selectedTab == .notes {
                Button {
                    store.syncNow()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Self.iconColor)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .opacity(store.sync.state.isBusy ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .disabled(store.sync.state.isBusy || store.scanConfig.syncedURLs().isEmpty)
                .help(store.scanConfig.syncedURLs().isEmpty
                      ? "Turn on Sync for a folder in Settings"
                      : "Sync with your iPhone or iPad on this network")
                .onHover { setHandCursor($0) }

                Button {
                    store.promptCreateNote()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Self.iconColor)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New note")
                .onHover { setHandCursor($0) }

                Button {
                    selectedTab = .settings
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Self.iconColor)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
                .onHover { setHandCursor($0) }
            } else {
                Button {
                    selectedTab = .notes
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Self.iconColor)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Done")
                .onHover { setHandCursor($0) }
            }
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

            if store.scanConfig.roots.isEmpty {
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
                let openPaths = store.windowManager.openPaths
                let activePath = store.windowManager.activePath
                List(store.filteredNotes) { note in
                    let isOpen = openPaths.contains(note.path.path)
                    let state = store.stateStore.storedState(for: note.path)
                    // Color only for open / recently opened — not after Remove from Recents.
                    let fileColor = store.noteColors[note.path.path]
                    let noteColor: NoteColor? = {
                        if isOpen { return fileColor ?? .default }
                        guard let state, state.lastOpenedAt != nil, state.removedFromRecentsAt == nil else {
                            return nil
                        }
                        return fileColor
                    }()
                    NoteListRow(
                        note: note,
                        isOpen: isOpen,
                        isActive: activePath == note.path.path,
                        noteColor: noteColor,
                        previewColor: fileColor ?? .default,
                        onOpen: { store.openNote(note) }
                    )
                    .contextMenu {
                        if store.isConflictCopy(note) {
                            Button("Merge with Original…") {
                                store.requestMerge(copy: note)
                            }
                        }
                        if store.canRemoveFromRecents(note) {
                            Button("Remove from Recents") {
                                store.removeFromRecents(note)
                            }
                        }
                    }
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

    private var includeRoots: [ScanRoot] {
        store.scanConfig.roots.filter { $0.kind == .include }
    }

    private var excludeRoots: [ScanRoot] {
        store.scanConfig.roots.filter { $0.kind == .exclude }
    }

    private var settingsPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    settingsFoldersSection

                    if !excludeRoots.isEmpty {
                        settingsIgnoredSection
                    }

                    if let scanErr = store.scanConfig.lastError {
                        Text(scanErr)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().opacity(0.18)

            settingsToolbar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
    }

    private var settingsFoldersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsDisclosureHeader(
                title: "Scanned Folders",
                count: includeRoots.count,
                isExpanded: showScannedFolders,
                helpExpanded: "Hide scanned folders",
                helpCollapsed: "Show folders searched for notes",
                onAdd: { store.addScanFolder() }
            ) {
                showScannedFolders.toggle()
            }

            if showScannedFolders {
                if includeRoots.isEmpty {
                    Text("Add a folder to look for notes.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(includeRoots) { root in
                            let isDefault = root.path.map(store.isDefaultCreateDirectory) ?? false
                            SettingsRuleRow(
                                title: ScanRuleDisplay.title(root),
                                folderURL: ScanRuleDisplay.folderURL(root),
                                pattern: root.pattern,
                                isDefault: isDefault,
                                isSynced: root.isSynced,
                                showsDefaultControl: root.isIncludeDirectory,
                                showsSyncControl: root.isIncludeDirectory,
                                onToggleDefault: {
                                    if let path = root.path {
                                        store.setDefaultCreateDirectory(path)
                                    }
                                },
                                onToggleSync: {
                                    store.setFolderSynced(root, enabled: !root.isSynced)
                                },
                                onRemove: {
                                    store.removeScanFolder(root)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private var settingsIgnoredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsDisclosureHeader(
                title: "Ignored Folders",
                count: excludeRoots.count,
                isExpanded: showIgnoredFolders,
                helpExpanded: "Hide ignored folders",
                helpCollapsed: "Show folders skipped while scanning",
                onAdd: nil
            ) {
                showIgnoredFolders.toggle()
            }

            if showIgnoredFolders {
                VStack(spacing: 0) {
                    ForEach(excludeRoots) { root in
                        SettingsRuleRow(
                            title: ScanRuleDisplay.title(root),
                            folderURL: ScanRuleDisplay.folderURL(root),
                            pattern: root.pattern,
                            isDefault: false,
                            isSynced: false,
                            showsDefaultControl: false,
                            showsSyncControl: false,
                            onToggleDefault: {},
                            onToggleSync: {},
                            onRemove: { store.removeScanFolder(root) }
                        )
                    }
                }
            }
        }
    }

    private var settingsToolbar: some View {
        HStack(spacing: 16) {
            Text("\(store.notes.count) notes")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button("Rescan") {
                store.reloadScanConfigFromDisk()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .onHover { setHandCursor($0) }
            .help("Reload folders and refresh the note list")

            Button("Config") {
                ScanConfig.ensureFileExists()
                NSWorkspace.shared.activateFileViewerSelecting([MarkdownStickiesConfig.scanConfigURL])
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .onHover { setHandCursor($0) }
            .help("Reveal scan.conf in Finder")
        }
    }

    private func setHandCursor(_ hovering: Bool) {
        if hovering { NSCursor.pointingHand.set() }
        else { NSCursor.arrow.set() }
    }
}

private enum ScanRuleDisplay {
    static func title(_ root: ScanRoot) -> String {
        if let path = root.path {
            let name = path.lastPathComponent
            return name.isEmpty ? root.pattern : name
        }
        let pattern = root.pattern
        if pattern.contains("*") { return pattern }
        let name = URL(fileURLWithPath: (pattern as NSString).expandingTildeInPath).lastPathComponent
        return name.isEmpty ? pattern : name
    }

    static func folderURL(_ root: ScanRoot) -> URL? {
        if let path = root.path { return path.standardizedFileURL }
        guard !root.pattern.contains("*") else { return nil }
        let expanded = (root.pattern as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
}

private struct SettingsDisclosureHeader: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let helpExpanded: String
    let helpCollapsed: String
    let onAdd: (() -> Void)?
    let toggle: () -> Void

    private static let iconColor = Color(nsColor: NSColor(calibratedWhite: 0.35, alpha: 1))

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(nsColor: NSColor(calibratedWhite: 0.2, alpha: 1)))
                    Text("\(count)")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? helpExpanded : helpCollapsed)
            .modifier(PointingHandCursor())

            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Self.iconColor)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Add folder")
                .modifier(PointingHandCursor())
            }
        }
    }
}

/// Shared settings row for scanned + ignored rules.
private struct SettingsRuleRow: View {
    let title: String
    let folderURL: URL?
    let pattern: String
    let isDefault: Bool
    let isSynced: Bool
    let showsDefaultControl: Bool
    let showsSyncControl: Bool
    let onToggleDefault: () -> Void
    let onToggleSync: () -> Void
    let onRemove: () -> Void

    @EnvironmentObject private var store: NoteStore
    @State private var starHovered = false
    @State private var removeHovered = false

    private static let ink = Color(nsColor: NSColor(calibratedWhite: 0.18, alpha: 1))
    private static let quiet = Color(nsColor: NSColor(calibratedWhite: 0.45, alpha: 1))
    private static let pathRootColor = Color(nsColor: NSColor(calibratedWhite: 0.42, alpha: 1))
    private static let pathRestColor = Color(nsColor: NSColor(calibratedWhite: 0.55, alpha: 1))

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showsDefaultControl {
                Button(action: onToggleDefault) {
                    Image(systemName: isDefault ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(isDefault ? Color.accentColor : Self.quiet.opacity(starHovered ? 1 : 0.4))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isDefault ? "New notes are created here" : "Use for new notes")
                .onHover { starHovered = $0 }
                .modifier(PointingHandCursor())
            }

            VStack(alignment: .leading, spacing: 3) {
                Button {
                    if let folderURL {
                        store.openFolderInFinder(folderURL)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Self.ink)
                            .lineLimit(1)
                        if isDefault {
                            Text("New notes")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(folderURL == nil)
                .help(folderURL == nil ? pattern : "Show in Finder")
                .modifier(PointingHandCursor(enabled: folderURL != nil))

                if let folderURL {
                    FolderPathLine(
                        segments: FolderPathDisplay.segments(forDirectory: folderURL),
                        rootColor: Self.pathRootColor,
                        restColor: Self.pathRestColor,
                        includeExcludeActions: false
                    )
                } else {
                    Text(pattern)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.pathRootColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsSyncControl {
                Toggle("Sync", isOn: Binding(
                    get: { isSynced },
                    set: { _ in onToggleSync() }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(isSynced ? "Synced with your iPhone or iPad — click to turn off" : "Sync this folder with your iPhone or iPad")
                .modifier(PointingHandCursor())
            }

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(removeHovered
                                     ? Color(nsColor: NSColor(calibratedWhite: 0.25, alpha: 1))
                                     : Self.quiet.opacity(0.28))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showsDefaultControl ? "Remove from scanned folders" : "Stop ignoring this folder")
            .onHover { removeHovered = $0 }
            .modifier(PointingHandCursor())
        }
        .padding(.vertical, 8)
        .contextMenu {
            if let folderURL {
                Button("Show in Finder") { store.openFolderInFinder(folderURL) }
            }
            if showsDefaultControl {
                Button(isDefault ? "Default for New Notes" : "Use for New Notes", action: onToggleDefault)
            }
            if showsSyncControl {
                Button(isSynced ? "Turn Sync Off" : "Turn Sync On", action: onToggleSync)
            }
            Divider()
            Button(showsDefaultControl ? "Remove" : "Stop Ignoring", role: .destructive, action: onRemove)
        }
    }
}

private struct PointingHandCursor: ViewModifier {
    var enabled: Bool = true

    func body(content: Content) -> some View {
        content.onHover { hovering in
            guard enabled else { return }
            if hovering { NSCursor.pointingHand.set() }
            else { NSCursor.arrow.set() }
        }
    }
}

/// Path crumbs from `~` (or volume root) down to a directory — shared by notes list + settings.
private enum FolderPathDisplay {
    static func segments(forDirectory directory: URL) -> [NoteLocationSegment] {
        let dir = directory.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if dir.path == home.path || dir.path.hasPrefix(home.path + "/") {
            var segments = [NoteLocationSegment(name: "~", url: home)]
            guard dir.path != home.path else { return segments }
            let relative = String(dir.path.dropFirst(home.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var current = home
            for part in relative.split(separator: "/").map(String.init) where !part.isEmpty {
                current = current.appendingPathComponent(part, isDirectory: true)
                segments.append(NoteLocationSegment(name: part, url: current.standardizedFileURL))
            }
            return segments
        }

        var segments: [NoteLocationSegment] = []
        var current = dir
        var parts: [URL] = [dir]
        while current.path != "/", current.pathComponents.count > 1 {
            current = current.deletingLastPathComponent()
            parts.append(current)
            if current.pathComponents.count <= 1 { break }
        }
        for url in parts.reversed() {
            let name = url.path == "/" ? "/" : url.lastPathComponent
            segments.append(NoteLocationSegment(name: name, url: url.standardizedFileURL))
        }
        return segments
    }
}

/// Monospaced clickable folder path — same control as the notes list.
private struct FolderPathLine: View {
    let segments: [NoteLocationSegment]
    let rootColor: Color
    let restColor: Color
    var includeExcludeActions: Bool = true

    @EnvironmentObject private var store: NoteStore

    var body: some View {
        HorizontalPathScroller {
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    if index > 0 {
                        Text("/")
                            .foregroundStyle(restColor)
                            .fixedSize()
                    }
                    PathFolderSegment(
                        name: segment.name,
                        isRoot: index == 0,
                        rootColor: rootColor,
                        restColor: restColor,
                        onOpen: { store.openFolderInFinder(segment.url) },
                        onExclude: includeExcludeActions
                            ? { store.excludeFolder(segment.url, includingSubfolders: false) }
                            : nil,
                        onExcludeTree: includeExcludeActions
                            ? { store.excludeFolder(segment.url, includingSubfolders: true) }
                            : nil
                    )
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: 11, design: .monospaced))
        }
        .frame(minHeight: 15)
    }
}

/// Owns hit-testing for the note title: pointing-hand cursor + click + hover tracking.
/// (SwiftUI `onHover` / pass-through cursor views get overwritten by `List`.)
private struct NoteTitleInteractionView: NSViewRepresentable {
    var onClick: () -> Void
    var onHover: (_ hovering: Bool, _ globalPoint: CGPoint?) -> Void

    func makeNSView(context: Context) -> NoteTitleInteractionNSView {
        let view = NoteTitleInteractionNSView()
        view.onClick = onClick
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: NoteTitleInteractionNSView, context: Context) {
        nsView.onClick = onClick
        nsView.onHover = onHover
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class NoteTitleInteractionNSView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool, CGPoint?) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .mouseEnteredAndExited,
                .mouseMoved,
                .cursorUpdate,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
        onHover?(true, Self.swiftUIGlobalMouse())
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
        onHover?(true, Self.swiftUIGlobalMouse())
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        onHover?(false, nil)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    /// `NSEvent.mouseLocation` is bottom-left; SwiftUI `.global` is top-left.
    private static func swiftUIGlobalMouse() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let maxY = screen?.frame.maxY ?? mouse.y
        return CGPoint(x: mouse.x, y: maxY - mouse.y)
    }
}

private struct NoteListRow: View {
    let note: Note
    let isOpen: Bool
    /// Key / focused sticky — title rendered black.
    let isActive: Bool
    /// Color from note-state when present (open or previously configured).
    let noteColor: NoteColor?
    /// Sticky fill used for the floating hover peek (defaults when never opened).
    let previewColor: NoteColor
    let onOpen: () -> Void

    @State private var isRowHovered = false
    @State private var isTitleHovered = false
    @State private var hoverPreviewTask: Task<Void, Never>?

    private static let titleColor = Color(nsColor: NSColor(calibratedWhite: 0.28, alpha: 1))
    private static let titleHoverColor = Color(nsColor: NSColor(calibratedWhite: 0.08, alpha: 1))
    private static let titleActiveColor = Color.black
    private static let pathRootColor = Color(nsColor: NSColor(calibratedWhite: 0.42, alpha: 1))
    private static let pathRestColor = Color(nsColor: NSColor(calibratedWhite: 0.55, alpha: 1))
    private static let swatchSize: CGFloat = 10

    private var titleForeground: Color {
        if isActive { return Self.titleActiveColor }
        if isTitleHovered || isRowHovered { return Self.titleHoverColor }
        return Self.titleColor
    }

    @EnvironmentObject private var store: NoteStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 10) {
                    colorSwatch
                        .frame(width: Self.swatchSize, height: Self.swatchSize)
                        .padding(.top, 3)

                    HStack(spacing: 6) {
                        Text(note.title)
                            .font(.system(size: 14, weight: .light))
                            .foregroundStyle(titleForeground)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if store.isConflictCopy(note) {
                            Text("Conflict copy")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                                .help("Right-click → Merge with Original…")
                        } else if store.hasConflictCopy(note) {
                            Text("Has conflict copy")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .allowsHitTesting(false)

                NoteTitleInteractionView(
                    onClick: {
                        dismissHoverPreview()
                        onOpen()
                    },
                    onHover: { hovering, _ in
                        if hovering {
                            let wasHovering = isTitleHovered
                            isTitleHovered = true
                            NoteHoverPreviewPanel.cancelScheduledHide()
                            if !wasHovering {
                                scheduleHoverPreview()
                            }
                        } else {
                            isTitleHovered = false
                            // Keep a show-task only while still intending to peek;
                            // leave an already-visible panel open for the grace period.
                            hoverPreviewTask?.cancel()
                            hoverPreviewTask = nil
                            NoteHoverPreviewPanel.scheduleHide()
                        }
                    }
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

            Group {
                if isRowHovered {
                    locationLine
                } else {
                    Color.clear.frame(height: 15)
                }
            }
            .padding(.leading, Self.swatchSize + 10)
            .accessibilityHidden(!isRowHovered)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isRowHovered ? Color.white : Color.clear)
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))
        .onHover { hovering in
            isRowHovered = hovering
        }
        .onDisappear { dismissHoverPreview() }
    }

    private func scheduleHoverPreview() {
        hoverPreviewTask?.cancel()
        let path = note.path
        let title = note.title
        let color = previewColor.nsColor
        hoverPreviewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: NoteHoverPreviewPanel.showDelayNanoseconds)
            guard !Task.isCancelled, isTitleHovered else { return }
            let body = await Task.detached(priority: .utility) {
                NoteHoverPreviewPanel.loadBody(from: path)
            }.value
            guard !Task.isCancelled, isTitleHovered else { return }
            NoteHoverPreviewPanel.show(title: title, body: body, color: color)
        }
    }

    private func dismissHoverPreview() {
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil
        NoteHoverPreviewPanel.hide()
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
        FolderPathLine(
            segments: FolderPathDisplay.segments(forDirectory: note.parentDirectory),
            rootColor: Self.pathRootColor,
            restColor: Self.pathRestColor,
            includeExcludeActions: true
        )
        .frame(height: 15)
    }
}

/// One folder crumb in a path line; click opens Finder (settings) or an action menu (notes list).
private struct PathFolderSegment: View {
    let name: String
    let isRoot: Bool
    let rootColor: Color
    let restColor: Color
    let onOpen: () -> Void
    let onExclude: (() -> Void)?
    let onExcludeTree: (() -> Void)?

    @State private var isHovered = false

    private static let hoverColor = Color(nsColor: NSColor(calibratedWhite: 0.05, alpha: 1))

    private var foreground: Color {
        isHovered ? Self.hoverColor : (isRoot ? rootColor : restColor)
    }

    var body: some View {
        // Plain text + AppKit menu: SwiftUI `Menu` swallows hover, so color never updates.
        Text(name)
            .foregroundStyle(foreground)
            .padding(.horizontal, 1)
            .padding(.vertical, 1)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.set() }
                else { NSCursor.arrow.set() }
            }
            .onTapGesture {
                if let onExclude, let onExcludeTree {
                    PathFolderNSMenu.popUp(
                        open: onOpen,
                        exclude: onExclude,
                        excludeTree: onExcludeTree
                    )
                } else {
                    onOpen()
                }
            }
            .help(name)
            .animation(.easeInOut(duration: 0.1), value: isHovered)
    }
}

/// Horizontal-only path scroller: no indicators, vertical wheel/trackpad goes to the list.
private struct HorizontalPathScroller<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> PathHorizontalScrollView {
        let scroll = PathHorizontalScrollView()
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.usesPredominantAxisScrolling = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = .init()

        let host = NSHostingView(rootView: content())
        host.translatesAutoresizingMaskIntoConstraints = true
        scroll.documentView = host
        context.coordinator.host = host
        return scroll
    }

    func updateNSView(_ scroll: PathHorizontalScrollView, context: Context) {
        guard let host = context.coordinator.host else { return }
        host.rootView = content()
        let fitting = host.fittingSize
        let height = max(ceil(fitting.height), 14)
        let width = max(ceil(fitting.width), 1)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        scroll.invalidateIntrinsicContentSize()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: NSHostingView<Content>?
    }
}

private final class PathHorizontalScrollView: NSScrollView {
    private enum AxisLock {
        case undecided
        case horizontal
        case vertical
    }

    private var axisLock: AxisLock = .undecided
    private var pendingDX: CGFloat = 0
    private var pendingDY: CGFloat = 0
    private var resetWorkItem: DispatchWorkItem?

    /// How far a gesture must travel before we commit to an axis (points).
    private let decideThreshold: CGFloat = 2.5
    /// After this idle gap, the next flick may pick a new axis.
    private let resetDelay: TimeInterval = 0.14

    override var intrinsicContentSize: NSSize {
        let height = documentView?.fittingSize.height ?? 15
        return NSSize(width: NSView.noIntrinsicMetric, height: max(ceil(height), 14))
    }

    override func scrollWheel(with event: NSEvent) {
        noteScrollActivity(event)

        // Fresh finger-down → new intention.
        if event.phase == .began {
            resetAxisLock()
        }
        if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            resetAxisLock()
            return
        }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        if axisLock == .undecided {
            pendingDX += dx
            pendingDY += dy
            let ax = abs(pendingDX)
            let ay = abs(pendingDY)
            if ax < decideThreshold && ay < decideThreshold {
                // Wait for a clearer direction so we don't lock on noise.
                return
            }
            axisLock = ax >= ay ? .horizontal : .vertical
            pendingDX = 0
            pendingDY = 0

            // Path can't scroll sideways → treat this gesture as list scrolling.
            if axisLock == .horizontal && !canScrollHorizontally {
                axisLock = .vertical
            }
        }

        switch axisLock {
        case .horizontal:
            // Consume the gesture (including any vertical component) so the list stays put.
            super.scrollWheel(with: event)
        case .vertical:
            forwardScrollToEnclosingList(event)
        case .undecided:
            break
        }
    }

    private var canScrollHorizontally: Bool {
        let contentWidth = documentView?.frame.width ?? 0
        return contentWidth > contentView.bounds.width + 0.5
    }

    private func noteScrollActivity(_ event: NSEvent) {
        resetWorkItem?.cancel()
        // Keep lock through trackpad momentum; only idle-reset when nothing is in progress.
        let momentumActive = event.momentumPhase == .began || event.momentumPhase == .changed
        let fingerActive = event.phase == .began || event.phase == .changed || event.phase == .mayBegin
        if momentumActive || fingerActive {
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.resetAxisLock()
        }
        resetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + resetDelay, execute: work)
    }

    private func resetAxisLock() {
        axisLock = .undecided
        pendingDX = 0
        pendingDY = 0
    }

    private func forwardScrollToEnclosingList(_ event: NSEvent) {
        var view: NSView? = superview
        while let current = view {
            if let scroll = current as? NSScrollView {
                scroll.scrollWheel(with: event)
                return
            }
            view = current.superview
        }
        nextResponder?.scrollWheel(with: event)
    }
}

/// Retains targets while an NSMenu is open (NSMenuItem targets are unowned).
@MainActor
private enum PathFolderNSMenu {
    private final class Target: NSObject {
        let open: () -> Void
        let exclude: () -> Void
        let excludeTree: () -> Void

        init(open: @escaping () -> Void, exclude: @escaping () -> Void, excludeTree: @escaping () -> Void) {
            self.open = open
            self.exclude = exclude
            self.excludeTree = excludeTree
        }

        @objc func openFolder(_ sender: Any?) { open() }
        @objc func excludeFolder(_ sender: Any?) { exclude() }
        @objc func excludeFolderTree(_ sender: Any?) { excludeTree() }
    }

    private static var retained: Target?

    static func popUp(
        open: @escaping () -> Void,
        exclude: @escaping () -> Void,
        excludeTree: @escaping () -> Void
    ) {
        let target = Target(open: open, exclude: exclude, excludeTree: excludeTree)
        retained = target

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Folder", action: #selector(Target.openFolder(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Exclude Folder", action: #selector(Target.excludeFolder(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(
            title: "Exclude Folder and All Subfolders",
            action: #selector(Target.excludeFolderTree(_:)),
            keyEquivalent: ""
        ))
        for item in menu.items where item.action != nil {
            item.target = target
        }

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        retained = nil
    }
}

private enum ControlTab {
    case notes
    case settings
}


import MarkdownStickiesCore
import SwiftUI
import UniformTypeIdentifiers

/// One horizontal screen: notes list, optionally with one note open.
struct NotePane: Identifiable, Equatable {
    let id: UUID
    /// `nil` = overview list; non-nil = that note is showing in this pane.
    var openNote: Note?

    static func overview() -> NotePane {
        NotePane(id: UUID(), openNote: nil)
    }

    var showsOverview: Bool { openNote == nil }
}

struct ContentView: View {
    @EnvironmentObject private var vault: VaultStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPickingFolder = false
    @State private var showingSettings = false
    @State private var showingNewNote = false
    @State private var newNoteTitle = "Untitled"
    @State private var panes: [NotePane] = [.overview()]
    @State private var selectedPaneID = UUID()
    @State private var didSeedSelection = false
    @State private var showFolderWarning = false

    var body: some View {
        Group {
            if vault.rootURL == nil {
                emptyFolderView
            } else {
                panePager
            }
        }
        .onAppear {
            vault.startIfNeeded()
            vault.ensureDiscoverable()
            if !didSeedSelection {
                selectedPaneID = panes[0].id
                didSeedSelection = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                vault.ensureDiscoverable()
            }
        }
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    vault.setFolder(url)
                    resetPanes()
                    showFolderWarning = vault.folderWarning != nil
                }
            case .failure(let error):
                vault.lastError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(isPickingFolder: $isPickingFolder)
            }
        }
        .overlay {
            if vault.sync.state != .idle {
                SyncBannerOverlay(
                    state: vault.sync.state,
                    onCancel: { vault.cancelSync() },
                    onDismiss: { vault.dismissSyncResult() }
                )
            }
        }
        .alert("Folder in iCloud Drive", isPresented: $showFolderWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vault.folderWarning ?? "")
        }
        .alert("New Note", isPresented: $showingNewNote) {
            TextField("Title", text: $newNoteTitle)
            Button("Create") { createNote() }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { vault.lastError != nil },
                set: { if !$0 { vault.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { vault.lastError = nil }
        } message: {
            Text(vault.lastError ?? "")
        }
    }

    /// Page TabView must not host NavigationStacks — UIKit crashes when pages remount.
    private var panePager: some View {
        TabView(selection: $selectedPaneID) {
            ForEach(panes) { pane in
                paneBody(for: pane)
                    .tag(pane.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    @ViewBuilder
    private func paneBody(for pane: NotePane) -> some View {
        if let note = pane.openNote {
            NoteEditorView(
                note: note,
                onBack: { backToOverview(paneID: pane.id) },
                onClosePane: { closePane(paneID: pane.id) }
            )
        } else {
            overviewPane(paneID: pane.id)
        }
    }

    private var emptyFolderView: some View {
        VStack(spacing: 0) {
            PaneChrome(
                title: "Notes",
                leading: { EmptyView() },
                trailing: { overviewTrailingButtons }
            )
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("No Folder")
                    .font(.title2.weight(.semibold))
                Text("Pick a folder that contains markdown notes. Access is stored on this device only.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Choose Folder") { isPickingFolder = true }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
    }

    private func overviewPane(paneID: UUID) -> some View {
        VStack(spacing: 0) {
            PaneChrome(
                title: "Notes",
                leading: { EmptyView() },
                trailing: { overviewTrailingButtons }
            )
            noteList(paneID: paneID)
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var overviewTrailingButtons: some View {
        HStack(spacing: 16) {
            if vault.rootURL != nil {
                Button {
                    vault.syncNow()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .disabled(vault.sync.state.isBusy)
                .accessibilityLabel("Sync with Mac")

                Button {
                    newNoteTitle = "Untitled"
                    showingNewNote = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New note")
            }

            Button {
                showingSettings = true
            } label: {
                Image(systemName: showingSettings ? "gearshape.fill" : "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }

    @ViewBuilder
    private func noteList(paneID: UUID) -> some View {
        let notes = vault.filteredNotes
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search notes", text: $vault.filterText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !vault.filterText.isEmpty {
                        Button {
                            vault.filterText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
            }
            if notes.isEmpty {
                Section {
                    if vault.isScanning {
                        ProgressView("Scanning…")
                    } else if vault.filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView(
                            "No Notes",
                            systemImage: "doc.text",
                            description: Text("Create a note or add a .md file into this folder.")
                        )
                    } else {
                        ContentUnavailableView(
                            "No Matches",
                            systemImage: "magnifyingglass",
                            description: Text("Try a different search.")
                        )
                    }
                }
            } else {
                Section {
                    ForEach(notes) { note in
                        Button {
                            openNote(note, in: paneID)
                        } label: {
                            HStack(alignment: .center, spacing: 8) {
                                Circle()
                                    .fill(vault.color(of: note)?.swiftUIColor ?? Color.clear)
                                    .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(note.title)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        if isNoteOpen(note) {
                                            Image(systemName: "doc.text")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .accessibilityLabel("Open in another pane")
                                        }
                                    }
                                    Text(subtitle(for: note))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if let label = statusLabel(for: note) {
                                        Text(label)
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { vault.rescan() }
    }

    private func statusLabel(for note: Note) -> String? {
        switch vault.status(of: note) {
        case .synced: return nil
        case .inbox: return "New — placed in a folder at the next sync"
        case .conflictCopy: return "Conflict copy — merge on the Mac"
        case .notSynced: return "Not synced"
        }
    }

    private func subtitle(for note: Note) -> String {
        guard let root = vault.rootURL else { return note.path.lastPathComponent }
        return Note.locationLabel(for: note.path, scanRoots: [root])
    }

    private func notePathKey(_ note: Note) -> String {
        note.path.standardizedFileURL.path
    }

    private func isNoteOpen(_ note: Note) -> Bool {
        paneID(showing: note) != nil
    }

    private func paneID(showing note: Note) -> UUID? {
        let key = notePathKey(note)
        return panes.first(where: { pane in
            guard let open = pane.openNote else { return false }
            return notePathKey(open) == key
        })?.id
    }

    private func openNote(_ note: Note, in paneID: UUID) {
        // Already open somewhere — jump to that pane; never duplicate.
        if let existing = self.paneID(showing: note) {
            withAnimation(.easeInOut(duration: 0.28)) {
                selectedPaneID = existing
            }
            return
        }
        guard let index = panes.firstIndex(where: { $0.id == paneID }) else { return }
        panes[index].openNote = note
        selectedPaneID = paneID
        vault.touchLastOpened(note.path)
        DispatchQueue.main.async {
            ensureOverviewNeighbors()
        }
    }

    private func backToOverview(paneID: UUID) {
        guard let index = panes.firstIndex(where: { $0.id == paneID }) else { return }
        panes[index].openNote = nil
        selectedPaneID = paneID
        DispatchQueue.main.async {
            collapseExtraOverviewsIfNeeded()
        }
    }

    private func closePane(paneID: UUID) {
        guard let index = panes.firstIndex(where: { $0.id == paneID }) else { return }
        if panes.count == 1 {
            panes[0].openNote = nil
            selectedPaneID = panes[0].id
            return
        }
        panes.remove(at: index)
        let next = panes[min(index, panes.count - 1)]
        selectedPaneID = next.id
        DispatchQueue.main.async {
            collapseExtraOverviewsIfNeeded()
        }
    }

    private func ensureOverviewNeighbors() {
        guard let selected = panes.first(where: { $0.id == selectedPaneID }),
              selected.openNote != nil
        else { return }

        if panes.first?.showsOverview != true {
            panes.insert(.overview(), at: 0)
        }
        if panes.last?.showsOverview != true {
            panes.append(.overview())
        }
    }

    private func collapseExtraOverviewsIfNeeded() {
        let anyNoteOpen = panes.contains { $0.openNote != nil }
        guard anyNoteOpen else {
            if panes.count != 1 || panes[0].openNote != nil {
                let keepID = panes.contains(where: { $0.id == selectedPaneID })
                    ? selectedPaneID
                    : UUID()
                panes = [NotePane(id: keepID, openNote: nil)]
                selectedPaneID = keepID
            }
            return
        }

        while panes.count > 1,
              panes[0].showsOverview,
              panes[1].showsOverview {
            let removed = panes.removeFirst()
            if removed.id == selectedPaneID {
                selectedPaneID = panes[0].id
            }
        }
        while panes.count > 1,
              panes[panes.count - 1].showsOverview,
              panes[panes.count - 2].showsOverview {
            let removed = panes.removeLast()
            if removed.id == selectedPaneID {
                selectedPaneID = panes[panes.count - 1].id
            }
        }
    }

    private func resetPanes() {
        let pane = NotePane.overview()
        panes = [pane]
        selectedPaneID = pane.id
    }

    private func createNote() {
        guard let note = vault.createNote(title: newNoteTitle) else { return }
        let targetID = panes.first(where: { $0.id == selectedPaneID })?.id
            ?? panes.first(where: { $0.showsOverview })?.id
            ?? selectedPaneID
        openNote(note, in: targetID)
    }
}

/// Lightweight top bar — avoids UINavigationBar inside the page TabView.
struct PaneChrome<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading()
                .frame(minWidth: 44, alignment: .leading)
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            trailing()
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

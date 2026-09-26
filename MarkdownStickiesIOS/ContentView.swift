import MarkdownStickiesCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var vault: VaultStore
    @State private var isPickingFolder = false
    @State private var showingSettings = false
    @State private var showingNewNote = false
    @State private var newNoteTitle = "Untitled"
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            rootContent
                .navigationTitle("Notes")
                .navigationDestination(for: Note.self) { note in
                    NoteEditorView(note: note)
                }
                .toolbar { trailingToolbar }
        }
        .onAppear { vault.startIfNeeded() }
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    vault.setFolder(url)
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

    @ViewBuilder
    private var rootContent: some View {
        if vault.rootURL == nil {
            // Keep searchable off this branch — searchable + ContentUnavailableView
            // has rendered as a blank white screen on device.
            VStack(spacing: 16) {
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        } else {
            noteList
                .searchable(text: $vault.filterText, prompt: "Search notes")
                .safeAreaInset(edge: .bottom) {
                    if let status = vault.syncService.lastStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.bar)
                    }
                }
        }
    }

    @ToolbarContentBuilder
    private var trailingToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 16) {
                if vault.rootURL != nil {
                    Button {
                        Task { await vault.syncNow() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .disabled(vault.syncService.isSyncing)
                    .accessibilityLabel("Sync")

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
    }

    @ViewBuilder
    private var noteList: some View {
        let notes = vault.filteredNotes
        if notes.isEmpty {
            VStack(spacing: 12) {
                if vault.isScanning {
                    ProgressView("Scanning…")
                } else if vault.filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Image(systemName: "doc.text")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No Notes")
                        .font(.title3.weight(.semibold))
                    Text("Create a note or add a .md file into this folder.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                } else {
                    Text("No Matches")
                        .font(.title3.weight(.semibold))
                    Text("Try a different search.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        } else {
            List(notes) { note in
                NavigationLink(value: note) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title)
                                .font(.headline)
                            Text(subtitle(for: note))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if vault.syncInboundPaths.contains(note.path.standardizedFileURL.path) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Received from peer")
                        }
                        if vault.syncOutboundPaths.contains(note.path.standardizedFileURL.path) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(.blue)
                                .accessibilityLabel("Sent to peer")
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        vault.moveNoteToTrash(note)
                    } label: {
                        Label("Trash", systemImage: "trash")
                    }
                }
            }
            .refreshable { vault.rescan() }
        }
    }

    private func subtitle(for note: Note) -> String {
        guard let root = vault.rootURL else { return note.path.lastPathComponent }
        return Note.locationLabel(for: note.path, scanRoots: [root])
    }

    private func createNote() {
        guard let root = vault.rootURL else { return }
        let title = newNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = title.isEmpty ? "Untitled" : title
        let url = NoteFilename.uniqueURL(in: root, date: Date(), title: effective)
        let initial = NoteFrontmatter.initialDocument(
            title: effective,
            createdOn: vault.deviceDisplayName
        )
        do {
            try initial.write(to: url, atomically: true, encoding: .utf8)
            let note = NoteFilename.parse(url: url.standardizedFileURL, modifiedAt: Date())
                ?? Note(
                    path: url.standardizedFileURL,
                    date: Date(),
                    title: effective,
                    modifiedAt: Date()
                )
            vault.rescan()
            navigationPath.append(note)
        } catch {
            vault.lastError = "Could not create note: \(error.localizedDescription)"
        }
    }
}

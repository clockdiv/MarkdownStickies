import MarkdownStickiesCore
import SwiftUI
import UIKit

struct NoteEditorView: View {
    let note: Note
    var onBack: () -> Void
    var onClosePane: () -> Void

    @EnvironmentObject private var vault: VaultStore
    @State private var editorID = UUID()
    /// Current file (follows renames and moves made by a sync).
    @State private var notePath: URL?
    /// Hash of the file as this editor last loaded or saved it. A save expects exactly this.
    @State private var loadedHash = ""
    /// The file as loaded, for keeping the `stickies-*` lines read-only.
    @State private var loadedData = Data()
    @State private var isReadOnly = false
    @State private var noteColor: Color?
    @State private var showFrontmatter = false
    @State private var frontmatterPrefix = ""
    @State private var editorText = ""
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var notice: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var previewImageURL: URL?
    @State private var missingImageMessage: String?
    /// True after the user changes text; load / chrome toggles must not mark dirty.
    @State private var isDirty = false
    @State private var isLoading = false

    private var path: URL { notePath ?? note.path }

    var body: some View {
        VStack(spacing: 0) {
            PaneChrome(title: isReadOnly ? note.title + " (read-only)" : note.title) {
                Button {
                    saveIfNeeded()
                    onBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel("Back")
            } trailing: {
                Menu {
                    Button {
                        toggleFrontmatter()
                    } label: {
                        Label(
                            showFrontmatter ? "Hide Frontmatter" : "Show Frontmatter",
                            systemImage: "curlybraces"
                        )
                    }
                    Button(role: .destructive) {
                        moveToTrash()
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    Button {
                        saveIfNeeded()
                        onClosePane()
                    } label: {
                        Label("Close Pane", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Note options")
            }

            MarkdownSourceEditor(
                text: $editorText,
                noteDirectory: path.deletingLastPathComponent(),
                isEditable: !isReadOnly,
                onOpenURL: openImageURL
            )
            .background(noteColor.map { $0.opacity(0.35) } ?? .clear)
        }
        .background(Color(.systemBackground))
        .onAppear {
            notePath = note.path
            load()
            vault.registerEditor(editorID) { saveIfNeeded() }
        }
        .onChange(of: editorText) { _, _ in
            guard !isLoading, !isReadOnly else { return }
            isDirty = true
            scheduleSave()
        }
        .onChange(of: isDirty) { _, dirty in
            vault.editors.setUnsavedEdits(dirty, for: path)
        }
        .onReceive(vault.fileChanges) { change in
            handleSyncChange(change)
        }
        .onDisappear {
            saveTask?.cancel()
            saveIfNeeded()
            vault.unregisterEditor(editorID)
            vault.editors.setUnsavedEdits(false, for: path)
        }
        .fullScreenCover(isPresented: Binding(
            get: { previewImageURL != nil },
            set: { if !$0 { previewImageURL = nil } }
        )) {
            if let previewImageURL {
                ImageQuickLook(url: previewImageURL) {
                    self.previewImageURL = nil
                }
                .ignoresSafeArea()
            }
        }
        .alert(
            "Could not open",
            isPresented: Binding(
                get: { loadError != nil },
                set: { if !$0 { loadError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loadError ?? "")
        }
        .alert(
            "Could not save",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .alert(
            "Note",
            isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
        .alert(
            "Image not found",
            isPresented: Binding(
                get: { missingImageMessage != nil },
                set: { if !$0 { missingImageMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(missingImageMessage ?? "")
        }
    }

    private func moveToTrash() {
        saveTask?.cancel()
        isDirty = false
        vault.moveNoteToTrash(Note(path: path, date: note.date, title: note.title, modifiedAt: note.modifiedAt))
        onBack()
    }

    private func openImageURL(_ url: URL) {
        if url.scheme == "http" || url.scheme == "https" {
            UIApplication.shared.open(url)
            return
        }
        let file = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: file.path) else {
            missingImageMessage = file.lastPathComponent
            return
        }
        previewImageURL = file
    }

    // MARK: - Document

    private var fullDocument: String {
        if showFrontmatter {
            return editorText
        }
        return NoteFrontmatter.joinDocument(prefix: frontmatterPrefix, body: editorText)
    }

    private func presentDocument(_ full: String) {
        let parts = NoteFrontmatter.splitDocument(full)
        frontmatterPrefix = parts.prefix
        isLoading = true
        editorText = showFrontmatter ? full : parts.body
        isLoading = false
    }

    private func toggleFrontmatter() {
        let full = fullDocument
        showFrontmatter.toggle()
        presentDocument(full)
    }

    /// Opening "touches" the note: `stickies-id` is added once if missing. A file that isn't
    /// UTF-8 or can't be written opens read-only.
    private func load() {
        guard let data = try? Data(contentsOf: path) else {
            loadError = "The file can’t be read."
            return
        }
        let hash = NoteHashing.fileHash(data)
        guard let text = String(data: data, encoding: .utf8) else {
            isReadOnly = true
            loadedHash = hash
            loadedData = data
            presentDocument(String(decoding: data, as: UTF8.self))
            notice = "This file isn’t UTF-8 text. It’s shown read-only and doesn’t sync."
            return
        }

        var current = data
        loadedHash = hash
        let ensured = StickiesFrontmatter.ensuringID(in: data)
        if ensured.didChange {
            do {
                guard let writer = vault.writer else { throw NoteWriter.Failure.missing }
                loadedHash = try writer.write(ensured.data, to: path, expect: .hash(hash), origin: .app)
                current = ensured.data
                vault.noteWritten(path)
            } catch {
                isReadOnly = true
                notice = "Markdown Stickies can’t write to this file. It’s shown read-only and doesn’t sync."
            }
        }
        loadedData = current
        presentDocument(current == data ? text : String(decoding: current, as: UTF8.self))
        noteColor = StickiesFrontmatter.color(in: current)?.swiftUIColor
        isDirty = false
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            saveIfNeeded()
        }
    }

    /// Saves through the shared writer, expecting the file to be what this editor loaded.
    /// If it changed meanwhile, the buffer becomes a conflict copy; nothing is overwritten.
    private func saveIfNeeded() {
        guard isDirty, !isReadOnly, let writer = vault.writer else { return }
        let data = keepingStickiesLines(Data(fullDocument.utf8))
        guard NoteHashing.fileHash(data) != loadedHash else {
            isDirty = false
            return
        }
        do {
            loadedHash = try writer.write(data, to: path, expect: .hash(loadedHash), origin: .app)
            loadedData = data
            vault.noteWritten(path)
            let saved = String(decoding: data, as: UTF8.self)
            if saved != fullDocument { presentDocument(saved) }   // a stickies-* line was put back
            isDirty = false
            saveError = nil
        } catch NoteWriter.Failure.changedOnDisk, NoteWriter.Failure.missing {
            saveAsConflictCopy(data)
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// The `stickies-*` lines are read-only on iOS (color is display-only, and removing the id
    /// must not make the Mac trash the note): their values from the loaded file are kept.
    private func keepingStickiesLines(_ data: Data) -> Data {
        var result = data
        for key in [StickiesFrontmatter.idKey, StickiesFrontmatter.colorKey, StickiesFrontmatter.conflictOfKey] {
            if let original = StickiesFrontmatter.value(for: key, in: loadedData) {
                result = StickiesFrontmatter.setting(key, to: original, in: result)
            } else {
                result = StickiesFrontmatter.removing(key, in: result)
            }
        }
        return result
    }

    private func saveAsConflictCopy(_ data: Data) {
        guard let writer = vault.writer else { return }
        let original = path
        var copy = StickiesFrontmatter.setting(StickiesFrontmatter.idKey, to: UUID().uuidString, in: data)
        if let originalID = StickiesFrontmatter.id(in: data) {
            copy = StickiesFrontmatter.setting(StickiesFrontmatter.conflictOfKey, to: originalID.uuidString, in: copy)
        }
        let name = ConflictCopy.filename(forOriginal: original.lastPathComponent, deviceName: vault.deviceDisplayName, date: Date())
        let directory = original.deletingLastPathComponent()
        var copyURL = directory.appendingPathComponent(name)
        var index = 2
        while NoteWriter.existsIgnoringCase(copyURL) {
            copyURL = directory.appendingPathComponent("\((name as NSString).deletingPathExtension) \(index).md")
            index += 1
        }
        do {
            let hash = try writer.write(copy, to: copyURL, expect: .absent, origin: .app)
            vault.noteWritten(copyURL)
            isDirty = false
            if FileManager.default.fileExists(atPath: original.path) {
                reloadFromDisk()
            } else {
                notePath = copyURL
                loadedHash = hash
                loadedData = copy
                presentDocument(String(decoding: copy, as: UTF8.self))
            }
            notice = "The note changed on disk while you were editing, so your version was saved as “\(copyURL.lastPathComponent)”."
            vault.rescan()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func reloadFromDisk() {
        guard let data = try? Data(contentsOf: path) else { return }
        loadedHash = NoteHashing.fileHash(data)
        loadedData = data
        presentDocument(String(decoding: data, as: UTF8.self))
        noteColor = StickiesFrontmatter.color(in: data)?.swiftUIColor
        isDirty = false
    }

    /// A sync changed this note: reload when clean, follow moves, close when trashed.
    /// With unsaved edits the sync doesn't touch the file at all, so nothing to do then.
    private func handleSyncChange(_ change: SyncFileChange) {
        let current = path.standardizedFileURL
        switch change {
        case .written(let url) where url == current:
            if !isDirty { reloadFromDisk() }
        case .moved(let from, let to) where from == current:
            vault.editors.setUnsavedEdits(false, for: from)
            notePath = to
            vault.editors.setUnsavedEdits(isDirty, for: to)
        case .trashed(let url) where url == current:
            isDirty = false
            onBack()
        default:
            break
        }
    }
}

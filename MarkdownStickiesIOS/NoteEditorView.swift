import MarkdownStickiesCore
import SwiftUI

struct NoteEditorView: View {
    let note: Note

    @EnvironmentObject private var vault: VaultStore
    @State private var showFrontmatter = false
    @State private var frontmatterPrefix = ""
    @State private var editorText = ""
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        TextEditor(text: $editorText)
            .font(.body.monospaced())
            .padding(8)
            .navigationTitle(note.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            toggleFrontmatter()
                        } label: {
                            Label(
                                showFrontmatter ? "Hide Frontmatter" : "Show Frontmatter",
                                systemImage: "curlybraces"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Note options")
                }
            }
            .onAppear {
                vault.acknowledgeInbound(for: note.path)
                load()
            }
            .onChange(of: editorText) { _, _ in scheduleSave() }
            .onDisappear {
                saveTask?.cancel()
                saveNow()
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
    }

    private var fullDocument: String {
        if showFrontmatter {
            return editorText
        }
        return NoteFrontmatter.joinDocument(prefix: frontmatterPrefix, body: editorText)
    }

    private func presentDocument(_ full: String) {
        let parts = NoteFrontmatter.splitDocument(full)
        frontmatterPrefix = parts.prefix
        editorText = showFrontmatter ? full : parts.body
    }

    private func toggleFrontmatter() {
        let full = fullDocument
        showFrontmatter.toggle()
        presentDocument(full)
    }

    private func load() {
        do {
            let raw = try String(contentsOf: note.path, encoding: .utf8)
            let ensured = NoteFrontmatter.ensuringSyncID(raw)
            presentDocument(ensured.markdown)
            if ensured.didChange {
                let previous = try note.path.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                try ensured.markdown.write(to: note.path, atomically: true, encoding: .utf8)
                if let previous {
                    try FileManager.default.setAttributes(
                        [.modificationDate: previous],
                        ofItemAtPath: note.path.path
                    )
                }
                vault.rescan()
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        do {
            let full = fullDocument
            try full.write(to: note.path, atomically: true, encoding: .utf8)
            if showFrontmatter {
                frontmatterPrefix = NoteFrontmatter.splitDocument(full).prefix
            }
            saveError = nil
            vault.rescan()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

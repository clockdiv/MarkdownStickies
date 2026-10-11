import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var vault: VaultStore
    @Environment(\.dismiss) private var dismiss
    @Binding var isPickingFolder: Bool
    @State private var confirmingFreshStart = false

    var body: some View {
        List {
            Section {
                if let root = vault.rootURL {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(root.lastPathComponent)
                            .font(.body.weight(.medium))
                        Text(root.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 2)

                    Button("Change Folder…") {
                        // Dismiss first so the parent’s fileImporter can present cleanly.
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            isPickingFolder = true
                        }
                    }

                    Button("Rescan Now") {
                        vault.rescan()
                    }
                } else {
                    Text("No folder selected.")
                        .foregroundStyle(.secondary)
                    Button("Choose Folder…") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            isPickingFolder = true
                        }
                    }
                }
            } header: {
                Text("Notes Folder")
            } footer: {
                Text("Choose a folder “On My iPhone”. New notes start at its top level; the next sync with the Mac places them in a folder.")
            }

            Section {
                TextField("Device name", text: $vault.deviceDisplayName)
                    .textInputAutocapitalization(.words)
            } header: {
                Text("This Device")
            } footer: {
                Text("Shown on the Mac during syncs and used for created_on on new notes. iOS hides the personal device name unless you set it here.")
            }

            if vault.rootURL != nil {
                Section {
                    Button("Start Fresh on This Device…") { confirmingFreshStart = true }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Use this after deleting or renaming folders here. The next sync treats this folder as new: nothing is deleted on the Mac or here, and the Mac sends its notes again.")
                }
            }

            if let warning = vault.folderWarning {
                Section("Notes Folder Location") {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog(
            "Start sync fresh on this device?",
            isPresented: $confirmingFreshStart,
            titleVisibility: .visible
        ) {
            Button("Start Fresh") { vault.startSyncFresh() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing is deleted. The next sync copies the Mac's notes into this folder again; notes that differ get a conflict copy.")
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}

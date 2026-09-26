import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var vault: VaultStore
    @Environment(\.dismiss) private var dismiss
    @Binding var isPickingFolder: Bool

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
                Text("Markdown Stickies reads .md files in this folder and its subfolders. Access stays on this device.")
            }

            Section {
                TextField("Device name", text: $vault.deviceDisplayName)
                    .textInputAutocapitalization(.words)
            } header: {
                Text("This Device")
            } footer: {
                Text("Used for created_on on new notes. iOS hides the personal device name unless you set it here.")
            }

            if let status = vault.syncService.lastStatus {
                Section("Sync") {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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

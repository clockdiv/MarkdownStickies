import MarkdownStickiesCore
import SwiftUI

/// A conflict copy and the note it belongs to, as loaded when the merge view opened.
struct MergeRequest: Identifiable {
    var id: String { copy.path.path }
    let original: Note
    let copy: Note
    let originalData: Data
    let copyData: Data

    var originalBody: String { NoteFrontmatter.splitDocument(String(decoding: originalData, as: UTF8.self)).body }
    var copyBody: String { NoteFrontmatter.splitDocument(String(decoding: copyData, as: UTF8.self)).body }
}

/// Two-way merge of a conflict copy into its original (spec §4, v1: two-way).
/// Saving writes the result into the original (keeping its frontmatter) and moves the copy
/// to the Trash. Nothing is written if either file changed since the view opened.
struct MergeView: View {
    let request: MergeRequest
    var onSave: (String) -> String?
    var onCancel: () -> Void

    @State private var result: String
    @State private var error: String?

    init(request: MergeRequest, onSave: @escaping (String) -> String?, onCancel: @escaping () -> Void) {
        self.request = request
        self.onSave = onSave
        self.onCancel = onCancel
        _result = State(initialValue: request.originalBody)
    }

    private var lines: [TextDiff.Line] {
        TextDiff.unified(local: request.originalBody, remote: request.copyBody)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge “\(request.copy.title)”")
                .font(.system(size: 17, weight: .semibold))
            Text("Red lines are only in “\(request.original.title)”, green lines only in the conflict copy. Edit the result below, then save. The copy then moves to the Trash.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        diffRow(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 140)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Text("Result")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Use Original") { result = request.originalBody }
                Button("Use Copy") { result = request.copyBody }
            }

            TextEditor(text: $result)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save Merge") {
                    error = onSave(result)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 560)
    }

    @ViewBuilder
    private func diffRow(_ line: TextDiff.Line) -> some View {
        switch line {
        case .same(let text):
            row(text, prefix: " ", color: .clear)
        case .removed(let text):
            row(text, prefix: "−", color: Color.red.opacity(0.15))
        case .added(let text):
            row(text, prefix: "+", color: Color.green.opacity(0.18))
        }
    }

    private func row(_ text: String, prefix: String, color: Color) -> some View {
        Text("\(prefix) \(text)")
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color)
            .textSelection(.enabled)
    }
}

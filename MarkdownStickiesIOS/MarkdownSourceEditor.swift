import MarkdownStickiesCore
import QuickLook
import SwiftUI
import UIKit

/// `UITextView` markdown source editor with tappable `![…](…)` image links.
struct MarkdownSourceEditor: UIViewRepresentable {
    @Binding var text: String
    var noteDirectory: URL
    var onOpenURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        tv.textContainer.lineFragmentPadding = 4
        tv.keyboardDismissMode = .interactive
        tv.alwaysBounceVertical = true
        tv.autocapitalizationType = .sentences
        tv.autocorrectionType = .default
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.dataDetectorTypes = []
        tv.isEditable = true
        tv.isSelectable = true
        applyTypography(to: tv)
        context.coordinator.applyText(text, to: tv, preserveSelection: false)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        applyTypography(to: uiView)
        if uiView.text != text {
            context.coordinator.applyText(text, to: uiView, preserveSelection: true)
        }
    }

    private func applyTypography(to textView: UITextView) {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let mono = UIFont.monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: mono)
        textView.font = font
        textView.adjustsFontForContentSizeCategory = true
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: UIColor.label
        ]
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: font
        ]
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownSourceEditor
        private var isApplyingAttributes = false

        init(_ parent: MarkdownSourceEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingAttributes else { return }
            parent.text = textView.text ?? ""
            applyImageLinks(in: textView, preserveSelection: true)
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith url: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            guard interaction == .invokeDefaultAction else { return true }
            parent.onOpenURL(url)
            return false
        }

        func applyText(_ text: String, to textView: UITextView, preserveSelection: Bool) {
            let selected = textView.selectedRange
            isApplyingAttributes = true
            defer { isApplyingAttributes = false }
            textView.text = text
            applyImageLinks(in: textView, preserveSelection: false)
            if preserveSelection {
                let maxLen = (textView.text as NSString).length
                textView.selectedRange = NSRange(location: min(selected.location, maxLen), length: 0)
            }
        }

        private func applyImageLinks(in textView: UITextView, preserveSelection: Bool) {
            let plain = textView.text ?? ""
            let font = textView.font
                ?? UIFontMetrics(forTextStyle: .body).scaledFont(
                    for: UIFont.monospacedSystemFont(
                        ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                        weight: .regular
                    )
                )
            let selected = textView.selectedRange
            let attributed = NSMutableAttributedString(
                string: plain,
                attributes: [
                    .font: font,
                    .foregroundColor: UIColor.label
                ]
            )

            let pattern = #"!\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^)]+))\s*\)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = plain as NSString
            let full = NSRange(location: 0, length: ns.length)
            regex.enumerateMatches(in: plain, options: [], range: full) { match, _, _ in
                guard let match else { return }
                let destRange = match.range(at: 2).location != NSNotFound
                    ? match.range(at: 2)
                    : match.range(at: 3)
                guard destRange.location != NSNotFound else { return }
                var dest = ns.substring(with: destRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if dest.hasPrefix("<"), dest.hasSuffix(">") {
                    dest = String(dest.dropFirst().dropLast())
                }
                guard let url = SyncImageAssets.resolveImageURL(dest, noteDirectory: parent.noteDirectory) else {
                    return
                }
                attributed.addAttribute(.link, value: url, range: match.range)
            }

            isApplyingAttributes = true
            textView.attributedText = attributed
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: UIColor.label
            ]
            if preserveSelection {
                let maxLen = attributed.length
                textView.selectedRange = NSRange(
                    location: min(selected.location, maxLen),
                    length: min(selected.length, max(0, maxLen - min(selected.location, maxLen)))
                )
            }
            isApplyingAttributes = false
        }
    }
}

// MARK: - Quick Look

struct ImageQuickLook: UIViewControllerRepresentable {
    let url: URL
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.url = url
        context.coordinator.onDismiss = onDismiss
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        context.coordinator.onDismiss = onDismiss
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var url: URL
        var onDismiss: () -> Void

        init(url: URL, onDismiss: @escaping () -> Void) {
            self.url = url
            self.onDismiss = onDismiss
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            onDismiss()
        }
    }
}

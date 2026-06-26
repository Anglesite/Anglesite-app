import AppKit
import SwiftUI

struct HTMLSnippetEditor: NSViewRepresentable {
    @Binding var text: String
    var onEditingEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEditingEnded: onEditingEnded)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.applyHighlighting(to: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.applyHighlighting(to: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        private let onEditingEnded: () -> Void
        private var isHighlighting = false

        init(text: Binding<String>, onEditingEnded: @escaping () -> Void) {
            self.text = text
            self.onEditingEnded = onEditingEnded
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            applyHighlighting(to: textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            onEditingEnded()
        }

        func applyHighlighting(to textView: NSTextView) {
            guard !isHighlighting else { return }
            isHighlighting = true
            defer { isHighlighting = false }

            let selectedRanges = textView.selectedRanges
            let source = textView.string as NSString
            let fullRange = NSRange(location: 0, length: source.length)
            let storage = textView.textStorage
            storage?.beginEditing()
            storage?.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ], range: fullRange)

            highlight(pattern: #"</?[\w:-]+|/?>"#, color: .systemBlue, in: source, storage: storage)
            highlight(pattern: #"[\w:-]+(?=\=)"#, color: .systemPurple, in: source, storage: storage)
            highlight(pattern: #""[^"]*"|'[^']*'"#, color: .systemGreen, in: source, storage: storage)
            highlight(pattern: #"<!--[\s\S]*?-->"#, color: .secondaryLabelColor, in: source, storage: storage)

            storage?.endEditing()
            textView.selectedRanges = selectedRanges
        }

        private func highlight(pattern: String, color: NSColor, in source: NSString, storage: NSTextStorage?) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(location: 0, length: source.length)
            for match in regex.matches(in: source as String, range: range) {
                storage?.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
    }
}

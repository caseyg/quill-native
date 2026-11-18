import SwiftUI
import UIKit
import QuillCore

/// Edits Markdown source with its formatting shown in place: the text stays Markdown,
/// and bold, headings, links and the rest are styled as you type, with their syntax faded.
struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    let controller: RichTextController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.smartDashesType = .no
        view.textContainerInset = UIEdgeInsets(top: 12, left: 15, bottom: 24, right: 15)
        view.accessibilityLabel = "Article"
        view.accessibilityIdentifier = "article.content"
        context.coordinator.view = view
        controller.target = context.coordinator
        view.text = text
        context.coordinator.restyle()
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        controller.target = context.coordinator
        guard view.text != text else { return }
        view.text = text
        context.coordinator.restyle()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, FormattingTarget {
        var parent: MarkdownEditor
        weak var view: UITextView?
        /// Kept while the link alert has focus, so the link goes where the selection was.
        private var selection = NSRange(location: 0, length: 0)

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text { parent.text = textView.text }
            restyle()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.isFirstResponder { selection = textView.selectedRange }
        }

        func textViewDidEndEditing(_ textView: UITextView) { restyle() }

        // MARK: Styling

        private static var body: UIFont { .preferredFont(forTextStyle: .body) }

        private static var base: [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            return [.font: body, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
        }

        /// Restyles the whole text from its Markdown. Posts are short, so this keeps up with typing.
        func restyle() {
            guard let view, view.markedTextRange == nil else { return }
            let storage = view.textStorage
            let full = NSRange(location: 0, length: storage.length)
            let spans = MarkdownStyle.spans(in: view.text).sorted { order($0.kind) < order($1.kind) }
            storage.beginEditing()
            storage.setAttributes(Self.base, range: full)
            for span in spans where NSMaxRange(span.range) <= storage.length { apply(span, to: storage) }
            storage.endEditing()
            view.typingAttributes = Self.base
        }

        /// Blocks first, then inline styles, then faded syntax on top.
        private func order(_ kind: MarkdownSpan.Kind) -> Int {
            switch kind {
            case .heading, .quote, .codeBlock: return 0
            case .marker: return 2
            default: return 1
            }
        }

        private func apply(_ span: MarkdownSpan, to storage: NSTextStorage) {
            let range = span.range
            switch span.kind {
            case .heading(let level):
                let style: UIFont.TextStyle = level == 1 ? .title1 : (level == 2 ? .title2 : .title3)
                storage.addAttribute(.font, value: Self.font(style, traits: .traitBold), range: range)
            case .quote:
                storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
            case .codeBlock:
                storage.addAttributes([.font: Self.monospaced(Self.body.pointSize * 0.9), .backgroundColor: UIColor.secondarySystemFill], range: range)
            case .strong: add(.traitBold, in: range, of: storage)
            case .emphasis: add(.traitItalic, in: range, of: storage)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .code:
                storage.enumerateAttribute(.font, in: range) { value, part, _ in
                    let size = (value as? UIFont)?.pointSize ?? Self.body.pointSize
                    storage.addAttribute(.font, value: Self.monospaced(size * 0.92), range: part)
                }
                storage.addAttribute(.backgroundColor, value: UIColor.secondarySystemFill, range: range)
            case .link:
                storage.addAttribute(.foregroundColor, value: UIColor.tintColor, range: range)
            case .marker:
                storage.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: range)
            }
        }

        private func add(_ trait: UIFontDescriptor.SymbolicTraits, in range: NSRange, of storage: NSTextStorage) {
            storage.enumerateAttribute(.font, in: range) { value, part, _ in
                let font = value as? UIFont ?? Self.body
                if let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait)) {
                    storage.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: part)
                }
            }
        }

        private static func font(_ style: UIFont.TextStyle, traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
            let font = UIFont.preferredFont(forTextStyle: style)
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }

        private static func monospaced(_ size: CGFloat) -> UIFont { .monospacedSystemFont(ofSize: size, weight: .regular) }

        // MARK: Commands

        func bold() { wrap("**") }
        func italic() { wrap("*") }

        /// Adds `## ` to the start of the current line, or removes the heading marks already there.
        func heading() {
            guard let view else { return }
            let text = view.text as NSString
            let selected = view.selectedRange
            let line = text.lineRange(for: NSRange(location: selected.location, length: 0))
            let current = text.substring(with: line)
            let hashes = current.prefix { $0 == "#" }.count
            if hashes > 0 {
                let marks = current.dropFirst(hashes).prefix { $0 == " " }.count + hashes
                replace(NSRange(location: line.location, length: marks), with: "", select: NSRange(location: max(line.location, selected.location - marks), length: selected.length))
            } else {
                replace(NSRange(location: line.location, length: 0), with: "## ", select: NSRange(location: selected.location + 3, length: selected.length))
            }
        }

        /// Makes the selection a link to `url`, or adds an empty link with the cursor where its text goes.
        func link(_ url: URL) {
            guard let view else { return }
            let length = (view.text as NSString).length
            let location = min(selection.location, length)
            let range = NSRange(location: location, length: min(selection.length, length - location))
            let label = (view.text as NSString).substring(with: range)
            let markdown = "[\(label)](\(url.absoluteString))"
            let cursor = label.isEmpty ? NSRange(location: location + 1, length: 0) : NSRange(location: location + (markdown as NSString).length, length: 0)
            view.becomeFirstResponder()
            replace(range, with: markdown, select: cursor)
        }

        /// Puts `mark` on both sides of the selection, or takes it away if it is already there.
        private func wrap(_ mark: String) {
            guard let view else { return }
            let text = view.text as NSString
            let range = view.selectedRange
            let count = (mark as NSString).length
            let selected = text.substring(with: range)
            if range.location >= count, NSMaxRange(range) + count <= text.length,
               text.substring(with: NSRange(location: range.location - count, length: count)) == mark,
               text.substring(with: NSRange(location: NSMaxRange(range), length: count)) == mark,
               !(mark == "*" && isBold(text, around: range)) {
                replace(NSRange(location: range.location - count, length: range.length + count * 2), with: selected, select: NSRange(location: range.location - count, length: range.length))
            } else {
                replace(range, with: mark + selected + mark, select: NSRange(location: range.location + count, length: range.length))
            }
        }

        /// Whether the `*` around a range is part of `**`, so italic doesn't unwrap bold.
        private func isBold(_ text: NSString, around range: NSRange) -> Bool {
            range.location >= 2 && NSMaxRange(range) + 2 <= text.length
                && text.substring(with: NSRange(location: range.location - 2, length: 2)) == "**"
                && text.substring(with: NSRange(location: NSMaxRange(range), length: 2)) == "**"
                && !(range.location >= 3 && NSMaxRange(range) + 3 <= text.length
                     && text.substring(with: NSRange(location: range.location - 3, length: 3)) == "***")
        }

        /// Replaces text through the text view, so the change can be undone.
        private func replace(_ range: NSRange, with string: String, select: NSRange) {
            guard let view,
                  let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: range.length),
                  let textRange = view.textRange(from: start, to: end) else { return }
            view.replace(textRange, withText: string)
            view.selectedRange = select
            textViewDidChange(view)
        }
    }
}

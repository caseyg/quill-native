import SwiftUI
import UIKit

/// Formatting commands for the article editor, sent from the composer's action bar.
@MainActor @Observable
final class RichTextController {
    @ObservationIgnored fileprivate weak var coordinator: RichEditor.Coordinator?
    func bold() { coordinator?.toggle(.traitBold) }
    func italic() { coordinator?.toggle(.traitItalic) }
    func heading() { coordinator?.heading() }
    func link(_ url: URL) { coordinator?.link(url) }
}

struct RichEditor: UIViewRepresentable {
    @Binding var html: String
    let controller: RichTextController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 15, bottom: 24, right: 15)
        view.accessibilityLabel = "Article"
        view.accessibilityIdentifier = "article.content"
        context.coordinator.view = view
        controller.coordinator = context.coordinator
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        let document = "<html><head><meta charset='utf-8'><style>body {font-family:-apple-system;font-size:17px;color:\(UIColor.label.hex);} img{max-width:100%;}</style></head><body>\(html)</body></html>"
        if let data = document.data(using: .utf8), let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
            view.attributedText = value
        } else {
            view.text = html
        }
        view.typingAttributes[.font] = UIFont.preferredFont(forTextStyle: .body)
        view.typingAttributes[.foregroundColor] = UIColor.label
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichEditor
        weak var view: UITextView?
        var lastHTML: String?
        private var selection = NSRange(location: 0, length: 0)

        init(_ parent: RichEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard let data = try? textView.attributedText.data(from: NSRange(location: 0, length: textView.attributedText.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue]), let html = String(data: data, encoding: .utf8) else { return }
            lastHTML = html
            parent.html = html
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.isFirstResponder { selection = textView.selectedRange }
        }

        func toggle(_ trait: UIFontDescriptor.SymbolicTraits) {
            guard let view else { return }
            let range = view.selectedRange
            if range.length > 0 {
                let text = NSMutableAttributedString(attributedString: view.attributedText)
                text.enumerateAttribute(.font, in: range) { value, part, _ in
                    let font = value as? UIFont ?? .preferredFont(forTextStyle: .body)
                    var traits = font.fontDescriptor.symbolicTraits
                    if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
                    if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                        text.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: part)
                    }
                }
                view.attributedText = text
                view.selectedRange = range
                textViewDidChange(view)
            } else {
                let font = view.typingAttributes[.font] as? UIFont ?? .preferredFont(forTextStyle: .body)
                var traits = font.fontDescriptor.symbolicTraits
                if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                    view.typingAttributes[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
                }
            }
        }

        func heading() {
            guard let view else { return }
            let selected = view.selectedRange
            let range = (view.text as NSString).paragraphRange(for: selected)
            let text = NSMutableAttributedString(attributedString: view.attributedText)
            text.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .title2), range: range)
            view.attributedText = text
            view.selectedRange = selected
            textViewDidChange(view)
        }

        func link(_ url: URL) {
            guard let view else { return }
            let text = NSMutableAttributedString(attributedString: view.attributedText)
            let range = NSRange(location: min(selection.location, text.length), length: min(selection.length, max(0, text.length - min(selection.location, text.length))))
            if range.length == 0 {
                text.insert(NSAttributedString(string: url.absoluteString, attributes: [.link: url, .font: UIFont.preferredFont(forTextStyle: .body)]), at: range.location)
            } else {
                text.addAttribute(.link, value: url, range: range)
            }
            view.attributedText = text
            textViewDidChange(view)
        }
    }
}

private extension UIColor {
    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolvedColor(with: .current).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var completion: (Data?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Data?) -> Void
        init(_ completion: @escaping (Data?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            completion((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.9))
        }
    }
}

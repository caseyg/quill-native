import SwiftUI
import UIKit

struct RichEditor: UIViewRepresentable {
    @Binding var html: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle:.body); view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear; view.isScrollEnabled = true
        view.accessibilityLabel = "Article content"
        view.accessibilityIdentifier = "article.content"
        let toolbar = UIToolbar(); toolbar.sizeToFit()
        context.coordinator.view = view
        toolbar.items = [
            UIBarButtonItem(image:UIImage(systemName:"bold"),style:.plain,target:context.coordinator,action:#selector(Coordinator.bold)),
            UIBarButtonItem(image:UIImage(systemName:"italic"),style:.plain,target:context.coordinator,action:#selector(Coordinator.italic)),
            UIBarButtonItem(title:"Heading",style:.plain,target:context.coordinator,action:#selector(Coordinator.heading)),
            UIBarButtonItem(image:UIImage(systemName:"link"),style:.plain,target:context.coordinator,action:#selector(Coordinator.link)),
            UIBarButtonItem(systemItem:.flexibleSpace),
            UIBarButtonItem(title:"Done",style:.done,target:context.coordinator,action:#selector(Coordinator.done))
        ]
        view.inputAccessoryView = toolbar
        updateUIView(view,context:context)
        return view
    }
    func updateUIView(_ view: UITextView,context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        let document = "<html><head><meta charset='utf-8'><style>body {font-family:-apple-system;font-size:17px;color:\(UIColor.label.hex);} img{max-width:100%;}</style></head><body>\(html)</body></html>"
        if let data = document.data(using:.utf8), let value = try? NSAttributedString(data:data,options:[.documentType:NSAttributedString.DocumentType.html,.characterEncoding:String.Encoding.utf8.rawValue],documentAttributes:nil) { view.attributedText = value }
        else { view.text = html }
        view.typingAttributes[.font] = UIFont.preferredFont(forTextStyle:.body)
        view.typingAttributes[.foregroundColor] = UIColor.label
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichEditor
        weak var view: UITextView?
        var lastHTML: String?
        init(_ parent: RichEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            guard let data = try? textView.attributedText.data(from:NSRange(location:0,length:textView.attributedText.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.html,.characterEncoding:String.Encoding.utf8.rawValue]), let html = String(data:data,encoding:.utf8) else { return }
            lastHTML = html; parent.html = html
        }
        private func trait(_ trait: UIFontDescriptor.SymbolicTraits) {
            guard let view else { return }
            let range = view.selectedRange
            let text = NSMutableAttributedString(attributedString:view.attributedText)
            if range.length > 0 {
                text.enumerateAttribute(.font,in:range) { value,r,_ in
                    let font = value as? UIFont ?? .preferredFont(forTextStyle:.body)
                    var traits = font.fontDescriptor.symbolicTraits
                    if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
                    if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { text.addAttribute(.font,value:UIFont(descriptor:descriptor,size:font.pointSize),range:r) }
                }
                view.attributedText = text; view.selectedRange = range; textViewDidChange(view)
            } else {
                let font = view.typingAttributes[.font] as? UIFont ?? .preferredFont(forTextStyle:.body)
                var traits = font.fontDescriptor.symbolicTraits
                if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { view.typingAttributes[.font] = UIFont(descriptor:descriptor,size:font.pointSize) }
            }
        }
        @objc func bold() { trait(.traitBold) }
        @objc func italic() { trait(.traitItalic) }
        @objc func heading() {
            guard let view else { return }
            let range = (view.text as NSString).paragraphRange(for:view.selectedRange)
            let text = NSMutableAttributedString(attributedString:view.attributedText)
            text.addAttribute(.font,value:UIFont.preferredFont(forTextStyle:.title2),range:range); view.attributedText = text; textViewDidChange(view)
        }
        @objc func link() {
            guard let view, let scene = view.window?.windowScene, let controller = scene.windows.first(where:\.isKeyWindow)?.rootViewController else { return }
            var top = controller; while let next = top.presentedViewController { top = next }
            let alert = UIAlertController(title:"Add link",message:"Select words first, then enter a URL.",preferredStyle:.alert)
            alert.addTextField { $0.placeholder = "https://…"; $0.keyboardType = .URL; $0.autocapitalizationType = .none }
            let range = view.selectedRange
            alert.addAction(UIAlertAction(title:"Cancel",style:.cancel))
            alert.addAction(UIAlertAction(title:"Add",style:.default) { [weak self] _ in
                guard let value = alert.textFields?.first?.text, let url = URL(string:value), ["https","http"].contains(url.scheme ?? "") else { return }
                let text = NSMutableAttributedString(attributedString:view.attributedText)
                if range.length == 0 { text.insert(NSAttributedString(string:value,attributes:[.link:url]),at:range.location) }
                else { text.addAttribute(.link,value:url,range:range) }
                view.attributedText = text; self?.textViewDidChange(view)
            }); top.present(alert,animated:true)
        }
        @objc func done() { view?.resignFirstResponder() }
    }
}
private extension UIColor {
    var hex: String { var r:CGFloat = 0,g:CGFloat = 0,b:CGFloat = 0,a:CGFloat = 0; resolvedColor(with:.current).getRed(&r,green:&g,blue:&b,alpha:&a); return String(format:"#%02x%02x%02x",Int(r*255),Int(g*255),Int(b*255)) }
}
struct HTMLPreview: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> UITextView { let v = UITextView(); v.isEditable = false; v.backgroundColor = .clear; v.font = .preferredFont(forTextStyle:.body); v.adjustsFontForContentSizeCategory = true; return v }
    func updateUIView(_ view: UITextView,context: Context) { view.attributedText = (try? NSAttributedString(data:Data(html.utf8),options:[.documentType:NSAttributedString.DocumentType.html,.characterEncoding:String.Encoding.utf8.rawValue],documentAttributes:nil)) ?? NSAttributedString(string:html); view.textColor = .label }
}
struct CameraPicker: UIViewControllerRepresentable {
    var completion: (Data?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController { let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ controller: UIImagePickerController,context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Data?) -> Void
        init(_ completion: @escaping (Data?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController,didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey:Any]) { completion((info[.originalImage] as? UIImage)?.jpegData(compressionQuality:0.9)) }
    }
}

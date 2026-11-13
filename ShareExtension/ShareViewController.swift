import UIKit
import Social
import UniformTypeIdentifiers
import QuillCore

final class ShareViewController: SLComposeServiceViewController {
    private var kind: PostKind = .note
    override func isContentValid() -> Bool { true }
    override func viewDidLoad() { super.viewDidLoad(); title = "Save to Quill"; navigationController?.navigationBar.topItem?.rightBarButtonItem?.title = "Save draft" }
    override func configurationItems() -> [Any]! {
        let item = SLComposeSheetConfigurationItem()!
        item.title = "Post type"; item.value = kind.title
        item.tapHandler = { [weak self] in
            guard let self else { return }
            let alert = UIAlertController(title:"Save as",message:nil,preferredStyle:.actionSheet)
            for kind in [PostKind.note,.bookmark,.reply,.like,.repost,.photo] { alert.addAction(UIAlertAction(title:kind.title,style:.default) { _ in self.kind = kind; self.reloadConfigurationItems() }) }
            alert.addAction(UIAlertAction(title:"Cancel",style:.cancel)); alert.popoverPresentationController?.sourceView = self.view; self.present(alert,animated:true)
        }
        return [item]
    }
    override func didSelectPost() {
        let text = contentText ?? ""
        Task { @MainActor in
            do {
                var draft = Draft(kind:kind); draft.content = text; draft.accountURL = SharedStorage.read(Account.self,key:"account")?.me
                for case let item as NSExtensionItem in extensionContext?.inputItems ?? [] {
                    for provider in item.attachments ?? [] {
                        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                            let value = try await load(provider,type:UTType.url.identifier)
                            if let url = value as? URL { draft.target = url.absoluteString; if kind == .note { draft.content += (draft.content.isEmpty ? "" : "\n") + url.absoluteString } }
                        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                            let value = try await load(provider,type:UTType.image.identifier)
                            let image: UIImage?
                            if let url = value as? URL { let accessing = url.startAccessingSecurityScopedResource(); defer { if accessing { url.stopAccessingSecurityScopedResource() } }; image = UIImage(data:try Data(contentsOf:url)) }
                            else if let data = value as? Data { image = UIImage(data:data) }
                            else { image = value as? UIImage }
                            if let data = image?.jpegData(compressionQuality:0.9) { draft.attachments.append(Attachment(data:data,filename:"shared-\(UUID().uuidString.prefix(8)).jpg",mimeType:"image/jpeg")); if kind == .note { draft.kind = .photo } }
                        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let value = try await load(provider,type:UTType.plainText.identifier) as? String, !draft.content.contains(value) { draft.content += (draft.content.isEmpty ? "" : "\n") + value }
                    }
                }
                try SharedStorage.drafts.save(draft)
                extensionContext?.completeRequest(returningItems:[],completionHandler:nil)
            } catch {
                let alert = UIAlertController(title:"Could not save draft",message:error.localizedDescription,preferredStyle:.alert)
                alert.addAction(UIAlertAction(title:"OK",style:.default)); present(alert,animated:true)
            }
        }
    }
    private func load(_ provider: NSItemProvider,type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in provider.loadItem(forTypeIdentifier:type,options:nil) { item,error in if let error { continuation.resume(throwing:error) } else if let item { continuation.resume(returning:item) } else { continuation.resume(throwing:QuillError("This shared item could not be read.")) } } }
    }
}

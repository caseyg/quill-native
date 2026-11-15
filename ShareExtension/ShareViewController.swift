import UIKit
import SwiftUI

/// Hosts the SwiftUI share editor and hands it what was shared.
final class ShareViewController: UIViewController {
    private lazy var model = ShareModel(
        finish: { [weak self] in self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil) },
        cancel: { [weak self] in self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareComposer(model: model).tint(Theme.tint))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        isModalInPresentation = true
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.load(items) }
    }
}

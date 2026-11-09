import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Rozszerzenie „Skryba” w arkuszu udostępniania (np. z Dyktafonu).
/// Przekazuje nagranie do aplikacji: przez wspólny kontener (App Group), a gdy go nie ma –
/// przez folder „Skryba” w aplikacji Pliki (wskazywany jednorazowo).
final class ShareViewController: UIViewController, UIDocumentPickerDelegate {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        model.presentFolderPicker = { [weak self] in
            self?.showFolderPicker()
        }
        model.openContainingApp = { [weak self] in
            self?.openSkryba() ?? false
        }

        let root = ShareRootView(model: model) { [weak self] in
            self?.close()
        }
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)

        model.start(with: extensionContext)
    }

    // MARK: - Wybór folderu Skryby

    private func showFolderPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        model.folderPicked(url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}

    // MARK: - Otwieranie Skryby

    /// Rozszerzenia nie mają oficjalnego sposobu na otwarcie swojej aplikacji,
    /// więc szukamy obiektu aplikacji w łańcuchu responderów. Jeśli iOS nie pozwoli,
    /// nic się nie stanie – zostaje powiadomienie i ekran „Gotowe”.
    private func openSkryba() -> Bool {
        guard let url = URL(string: "skryba://inbox") else { return false }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector),
               let implementation = current.method(for: selector) {
                typealias OpenURLFunction = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(implementation, to: OpenURLFunction.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}

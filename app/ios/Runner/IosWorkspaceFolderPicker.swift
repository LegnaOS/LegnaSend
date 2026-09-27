import UIKit
import UniformTypeIdentifiers

final class IosWorkspaceFolderPicker: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
  private weak var activePicker: UIDocumentPickerViewController?
  private var completion: ((Result<URL?, Error>) -> Void)?
  enum Failure: Error { case busy, unavailable }
  func present(completion: @escaping (Result<URL?, Error>) -> Void) {
    guard self.completion == nil else { completion(.failure(Failure.busy)); return }
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
    guard var presenter = (windows.first(where: { $0.isKeyWindow }) ?? windows.first(where: { !$0.isHidden }))?.rootViewController else {
      completion(.failure(Failure.unavailable)); return
    }
    while let next = presenter.presentedViewController { presenter = next }
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) { picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false) }
    else { picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open) }
    picker.allowsMultipleSelection = false; picker.delegate = self
    self.completion = completion
    self.activePicker = picker
    presenter.present(picker, animated: true)
    picker.presentationController?.delegate = self
  }
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    guard let picker = presentationController.presentedViewController as? UIDocumentPickerViewController else { return }
    finish(.success(nil), controller: picker)
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(.success(nil), controller: controller) }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard urls.count == 1, let url = urls.first, url.isFileURL else { finish(.failure(Failure.unavailable), controller: controller); return }
    finish(.success(url), controller: controller)
  }
  private func finish(_ result: Result<URL?, Error>, controller: UIDocumentPickerViewController) {
    guard controller === activePicker else { return }
    let callback = completion; completion = nil; activePicker = nil; callback?(result)
  }
}

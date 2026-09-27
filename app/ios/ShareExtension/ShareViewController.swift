import UIKit
import UniformTypeIdentifiers

/// Imports finish before the extension completes. No private application-opening
/// trick is required: the host drains durable manifests on startup/resume.
final class ShareViewController: UIViewController {
  private var store: IosDropStore?
  private var inbox: IosShareInbox?
  private var batch: URL?
  private var progress: Progress?
  private var cancelled = false
  private let worker = DispatchQueue(label: "legnasend.share-import", qos: .userInitiated)
  private let workerKey = DispatchSpecificKey<Bool>()
  private let stateLock = NSLock()
  private let label = UILabel()
  private let button = UIButton(type: .system)
  private var finished = false
  private var committed = false
  private func copy(_ english: String, _ simplified: String, _ traditional: String) -> String {
    let language = Locale.preferredLanguages.first ?? "en"
    guard language.hasPrefix("zh") else { return english }
    return ["Hant", "TW", "HK", "MO"].contains(where: language.contains) ? traditional : simplified
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    worker.setSpecific(key: workerKey, value: true)
    view.backgroundColor = .systemBackground
    label.numberOfLines = 0; label.textAlignment = .center
    label.font = .preferredFont(forTextStyle: .body)
    label.adjustsFontForContentSizeCategory = true
    button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.titleLabel?.numberOfLines = 0
    button.titleLabel?.lineBreakMode = .byWordWrapping
    button.titleLabel?.textAlignment = .center
    label.text = copy("Importing into LegnaSend…", "正在导入到 LegnaSend…", "正在匯入到 LegnaSend…")
    button.setTitle(copy("Cancel", "取消", "取消"), for: .normal)
    button.addTarget(self, action: #selector(close), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [label, button]); stack.axis = .vertical; stack.spacing = 24
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll); scroll.addSubview(stack)
    // Intrinsic Dynamic Type height can exceed landscape safe-area height.
    // Keep both status and the explicit cancel/done action reachable by scrolling.
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
    guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String,
          let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { showFailure(); return }
    let root = container.appendingPathComponent(".legnasend-share-inbox", isDirectory: true)
    store = IosDropStore(root: root); inbox = IosShareInbox(root: root)
    let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    let providers = items.flatMap { $0.attachments ?? [] }
    let text = items.filter { ($0.attachments ?? []).isEmpty }.compactMap { $0.attributedContentText?.string }
    guard providers.count <= 999, !providers.isEmpty || !text.isEmpty else { showFailure(); return }
    worker.async {
      do {
        self.batch = try self.store?.begin()
        self.load(providers, index: 0, files: [], text: text)
      } catch { self.fail() }
    }
  }
  private var isCancelled: Bool { stateLock.lock(); defer { stateLock.unlock() }; return cancelled }
  private func setProgress(_ value: Progress?) {
    stateLock.lock(); progress = value; let stop = cancelled; stateLock.unlock()
    if stop { value?.cancel() }
  }
  @objc private func close() {
    if finished { extensionContext?.completeRequest(returningItems: [], completionHandler: nil); return }
    stateLock.lock()
    if committed {
      stateLock.unlock()
      extensionContext?.completeRequest(returningItems: [], completionHandler: nil); return
    }
    cancelled = true; let active = progress; stateLock.unlock()
    active?.cancel()
    worker.async { if let batch = self.batch { self.store?.finish(batch, keep: false) } }
    extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
  }
  private func fail() {
    if let batch = batch { store?.finish(batch, keep: false) }
    DispatchQueue.main.async { if !self.isCancelled { self.showFailure() } }
  }
  private func showFailure() {
    label.text = copy("Import failed. Select the files again and retry.", "导入失败，请重新选择文件后重试。", "匯入失敗，請重新選擇檔案後重試。")
  }
  private func load(_ providers: [NSItemProvider], index: Int, files: [[String: Any]], text: [String]) {
    guard !isCancelled, let batch = batch, let store = store, let inbox = inbox else { fail(); return }
    guard index < providers.count else {
      do {
        // close() may arrive during publication; serialize its decision with commit.
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !cancelled else { store.finish(batch, keep: false); return }
        try inbox.publish(batch: batch, attachments: files, text: text)
        committed = true
        store.finish(batch, keep: true)
        DispatchQueue.main.async {
          self.finished = true
          self.label.text = self.copy("Imported. Open LegnaSend to send.", "已导入。打开 LegnaSend 即可发送。", "已匯入。開啟 LegnaSend 即可傳送。")
          self.button.setTitle(self.copy("Done", "完成", "完成"), for: .normal)
        }
      } catch { fail() }
      return
    }
    let provider = providers[index]
    let fileType = provider.registeredTypeIdentifiers.first {
      guard let type = UTType($0) else { return false }
      return type.conforms(to: .data) && !type.conforms(to: .text) && type != .fileURL && type != .url
    }
    let fileURL = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    if fileURL || fileType != nil {
      let type = fileType ?? UTType.fileURL.identifier
      let completion: (URL?, Error?) -> Void = { url, error in
        guard let url = url, error == nil else { self.worker.async { self.fail() }; return }
        // Provider URLs expire when this callback returns. Copy synchronously
        // on our serial worker, then advance without retaining external URLs.
        let copyFile = {
          guard !self.isCancelled else { self.fail(); return }
          do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory != true else { throw IosShareInbox.Failure.invalidManifest }
            let copy = try store.copy(source: url, suggestedName: provider.suggestedName, index: index, batch: batch)
            let kind = UTType(type)
            let attachmentType = kind?.conforms(to: .image) == true ? 0 : kind?.conforms(to: .movie) == true ? 1 : kind?.conforms(to: .audio) == true ? 2 : 3
            self.worker.async { self.load(providers, index: index + 1, files: files + [["path": copy.path, "type": attachmentType]], text: text) }
          } catch { self.fail() }
        }
        if DispatchQueue.getSpecific(key: self.workerKey) == true { copyFile() }
        else { self.worker.sync(execute: copyFile) }
      }
      // Invoke providers away from the serial worker to allow synchronous callbacks.
      DispatchQueue.global(qos: .userInitiated).async {
        if fileURL {
          provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
            completion((value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }, error)
          }
        } else { self.setProgress(provider.loadFileRepresentation(forTypeIdentifier: type, completionHandler: completion)) }
      }
    } else {
      let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url.identifier : UTType.text.identifier
      provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
        let value = (item as? URL)?.absoluteString ?? (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        self.worker.async {
          guard error == nil, let value = value else { self.fail(); return }
          self.load(providers, index: index + 1, files: files, text: text + [value])
        }
      }
    }
  }
}

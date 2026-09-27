import Foundation
import UIKit
import MobileCoreServices

/// Adapter for desktop_drop 0.7.1's existing Dart event contract. No second
/// Flutter drop target or transport exists; the HomePage owns dispatch once.
final class IosDropInteraction: NSObject, UIDropInteractionDelegate {
  typealias Send = (String, Any?, ((Any?) -> Void)?) -> Void
  private let event: Send
  private let control: Send
  private let store: IosDropStore
  private weak var view: UIView?
  private var interaction: UIDropInteraction?
  private var busy = false

  init(store: IosDropStore, event: @escaping Send, control: @escaping Send) {
    self.store = store; self.event = event; self.control = control
    super.init()
  }

  func attach(to view: UIView) {
    guard self.view !== view else { return }
    if let old = interaction { self.view?.removeInteraction(old) }
    self.view = view
    let next = UIDropInteraction(delegate: self)
    view.addInteraction(next)
    interaction = next
  }

  private func identifier(_ provider: NSItemProvider) -> String? {
    if provider.hasItemConformingToTypeIdentifier("public.folder") { return "public.folder" }
    if let type = provider.registeredTypeIdentifiers.first(where: {
      $0 != "public.file-url" && (UTTypeConformsTo($0 as CFString, kUTTypeData) || UTTypeConformsTo($0 as CFString, kUTTypeDirectory))
    }) { return type }
    return provider.hasItemConformingToTypeIdentifier("public.file-url") ? "public.file-url" : nil
  }

  func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
    return !busy && !session.items.isEmpty && session.items.allSatisfy { identifier($0.itemProvider) != nil }
  }

  private func point(_ session: UIDropSession) -> [Double] {
    guard let view = view else { return [-1, -1] }
    let point = session.location(in: view)
    return [Double(point.x), Double(point.y)] // UIKit points are Flutter logical pixels on iOS.
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
    event("entered", point(session), nil)
  }
  func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
    event("updated", point(session), nil)
    return UIDropProposal(operation: busy ? .cancel : .copy)
  }
  func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) { event("exited", nil, nil) }
  func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) { event("exited", nil, nil) }

  func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
    guard !busy else { return }
    busy = true
    let location = point(session)
    let providers = session.items.map { $0.itemProvider }
    // Freeze the Dart target at the user's release position before slow iCloud
    // or Photos materialization. A hidden/modal route rejects the whole drop.
    control("prepare", location) { [weak self] accepted in
      guard let self = self else { return }
      guard accepted as? Bool == true else { self.busy = false; self.event("exited", nil, nil); return }
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let batch = try self.store.begin()
          self.load(providers, index: 0, paths: [], batch: batch, location: location)
        } catch { self.fail(nil) }
      }
    }
  }

  private func fail(_ batch: URL?) {
    if let batch = batch { store.finish(batch, keep: false) }
    DispatchQueue.main.async {
      self.busy = false
      self.event("exited", nil, nil)
      self.control("failed", "importFailed", nil)
    }
  }

  private func load(_ providers: [NSItemProvider], index: Int, paths: [String], batch: URL, location: [Double]) {
    guard index < providers.count else {
      DispatchQueue.main.async {
        // Some UIKit providers end the drag before their async files arrive.
        // updated re-enters DropTarget safely without duplicate-enter assertions.
        self.event("updated", location) { _ in
          self.event("performOperation", paths) { _ in
            self.store.finish(batch, keep: true)
            self.busy = false
          }
        }
      }
      return
    }
    let provider = providers[index]
    guard let type = identifier(provider) else { fail(batch); return }
    DispatchQueue.global(qos: .userInitiated).async {
      let received: (URL?, Error?) -> Void = { url, error in
        guard let url = url, error == nil else { self.fail(batch); return }
        do {
          // The exported URL expires when this completion returns. Copy inside
          // the callback; security scope ends only after our private copy exists.
          let file = try self.store.copy(source: url, suggestedName: provider.suggestedName, index: index, batch: batch)
          self.load(providers, index: index + 1, paths: paths + [file.path], batch: batch, location: location)
        } catch { self.fail(batch) }
      }
      if type == "public.file-url" {
        provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
          let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
          received(url, error)
        }
      } else {
        provider.loadFileRepresentation(forTypeIdentifier: type, completionHandler: received)
      }
    }
  }
}

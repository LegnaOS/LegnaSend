import Cocoa
import FlutterMacOS

/// Same private grant/lease contract as iOS. Kept alive by AppDelegate, not by a
/// window: closing or hiding the UI must not revoke a still-serving workspace.
final class MacosWorkspaceGrants {
  private let channel: FlutterMethodChannel
  private let store: IosWorkspaceGrantStore
  private let queue = DispatchQueue(label: "legnasend.macos-workspace-grants", qos: .userInitiated)
  private weak var window: NSWindow?
  private var picker: NSOpenPanel?

  init(messenger: FlutterBinaryMessenger, window: NSWindow?, root: URL) {
    self.window = window
    self.store = IosWorkspaceGrantStore(root: root)
    self.channel = FlutterMethodChannel(name: "legnasend/ios_workspace", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, reply in
      guard let self = self else {
        reply(FlutterError(code: "grantUnavailable", message: "Workspace authorization unavailable", details: nil)); return
      }
      self.handle(call, reply: reply)
    }
  }

  private func respond(_ reply: @escaping FlutterResult, work: @escaping () throws -> Any?) {
    queue.async {
      do { let value = try work(); DispatchQueue.main.async { reply(value) } }
      catch {
        DispatchQueue.main.async {
          reply(FlutterError(code: "grantUnavailable", message: "Select the folder again to restore access", details: nil))
        }
      }
    }
  }

  private func pick(_ reply: @escaping FlutterResult) {
    guard picker == nil else {
      reply(FlutterError(code: "grantUnavailable", message: "A folder selection is already open", details: nil)); return
    }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.resolvesAliases = true
    picker = panel
    let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
      guard let self = self, let panel = panel, self.picker === panel else {
        reply(FlutterError(code: "grantUnavailable", message: "Folder selection unavailable", details: nil)); return
      }
      self.picker = nil
      guard response == .OK else { reply(nil); return }
      guard panel.urls.count == 1, let url = panel.urls.first, url.isFileURL else {
        reply(FlutterError(code: "grantUnavailable", message: "Select a local directory", details: nil)); return
      }
      self.respond(reply) { try self.store.save(url) }
    }
    if let window = window, window.attachedSheet == nil { panel.beginSheetModal(for: window, completionHandler: finish) }
    else { panel.begin(completionHandler: finish) }
  }

  private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    func invalid() { reply(FlutterError(code: "invalid", message: "Missing workspace grant arguments", details: nil)) }
    switch call.method {
    case "pick":
      pick(reply)
    case "probe":
      guard let id = args?["grantId"] as? String else { invalid(); return }
      respond(reply) { try self.store.probe(id) }
    case "acquire":
      guard let ids = args?["grantIds"] as? [String], args?["leaseId"] == nil || args?["leaseId"] is String else { invalid(); return }
      respond(reply) { try self.store.acquire(ids, retaining: args?["leaseId"] as? String) }
    case "retainOnly":
      guard let lease = args?["leaseId"] as? String, let ids = args?["grantIds"] as? [String] else { invalid(); return }
      respond(reply) { try self.store.retainOnly(lease, ids: ids) }
    case "release":
      guard let lease = args?["leaseId"] as? String else { invalid(); return }
      // Dart releases only after its exact server ack and worker drain barrier.
      respond(reply) { self.store.release(lease); return true }
    case "adopt":
      guard let id = args?["grantId"] as? String else { invalid(); return }
      respond(reply) { try self.store.adopt(id); return true }
    case "prune":
      guard let ids = args?["grantIds"] as? [String] else { invalid(); return }
      respond(reply) { try self.store.prune(ids); return true }
    case "discard":
      guard let id = args?["grantId"] as? String else { invalid(); return }
      respond(reply) { try self.store.discard(id); return true }
    default:
      reply(FlutterMethodNotImplemented)
    }
  }
}

import CFNetwork
import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nativeDrop: IosDropInteraction?
  private let workspacePicker = IosWorkspaceFolderPicker()
  private let receivePicker = IosWorkspaceFolderPicker()
  private let workspaceGrantQueue = DispatchQueue(label: "legnasend.workspace-grants", qos: .userInitiated)
  private var dropObservers: [NSObjectProtocol] = []

  private func attachNativeDrop() {
    func flutterView(_ controller: UIViewController?) -> UIView? {
      guard let controller = controller else { return nil }
      if controller is FlutterViewController { return controller.view }
      for child in controller.children { if let view = flutterView(child) { return view } }
      return flutterView(controller.presentedViewController)
    }
    for scene in UIApplication.shared.connectedScenes {
      guard let scene = scene as? UIWindowScene else { continue }
      for window in scene.windows where !window.isHidden {
        if let view = flutterView(window.rootViewController) { nativeDrop?.attach(to: view); return }
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let channel = FlutterMethodChannel(
        name: "ios-delegate-channel",
        binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        if call.method == "networkSignals" {
          let keys = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
          let values = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
          let enabled = keys.contains { (values?[$0] as? NSNumber)?.boolValue == true }
          result(["proxyKnown": values != nil, "proxyEnabled": enabled, "vpnKnown": false])
        } else if call.method == "isReduceMotionEnabled" {
          result(UIAccessibility.isReduceMotionEnabled)
        } else {
          result(FlutterMethodNotImplemented)
        }
    }
    let shareChannel = FlutterMethodChannel(name: "legnasend/ios_share", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    shareChannel.setMethodCallHandler { [weak self] call, reply in
      guard let self = self,
            let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String,
            let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
        reply(FlutterError(code: "shareUnavailable", message: "Share inbox unavailable", details: nil)); return
      }
      let inbox = IosShareInbox(root: container.appendingPathComponent(".legnasend-share-inbox", isDirectory: true))
      let args = call.arguments as? [String: Any]
      self.workspaceGrantQueue.async {
        do {
          let value: Any?
          switch call.method {
          case "next": value = try inbox.next()
          case "acknowledge":
            guard let id = args?["batchId"] as? String else { throw IosShareInbox.Failure.invalidBatch }
            try inbox.acknowledge(id); value = nil
          default: value = FlutterMethodNotImplemented
          }
          DispatchQueue.main.async { reply(value) }
        } catch { DispatchQueue.main.async { reply(FlutterError(code: "shareUnavailable", message: "Share import is pending; retry after restoring file access", details: nil)) } }
      }
    }
    let dropEvents = FlutterMethodChannel(name: "desktop_drop", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    let dropControl = FlutterMethodChannel(name: "legnasend/ios_drop", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      let receiveGrants = IosReceiveGrantStore(root: support.appendingPathComponent(".legnasend-receive-grants", isDirectory: true))
      let receiveChannel = FlutterMethodChannel(name: "legnasend/ios_receive", binaryMessenger: engineBridge.applicationRegistrar.messenger())
      receiveChannel.setMethodCallHandler { [weak self] call, reply in
        guard let self = self else { reply(FlutterError(code: "receiveGrantUnavailable", message: "Select the folder again", details: nil)); return }
        func fail() { reply(FlutterError(code: "receiveGrantUnavailable", message: "Select the folder again", details: nil)) }
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "pick":
          self.receivePicker.present { result in
            switch result {
            case .success(let url):
              guard let url = url else { reply(nil); return }
              self.workspaceGrantQueue.async {
                do { let path = try receiveGrants.save(url); DispatchQueue.main.async { reply(path) } }
                catch { DispatchQueue.main.async { fail() } }
              }
            case .failure: fail()
            }
          }
        case "acquire", "acquireMaintenance":
          guard let path = args?["path"] as? String else { fail(); return }
          receiveGrants.acquire(path, maintenance: call.method == "acquireMaintenance") { result in
            switch result {
            case .success(let lease): reply(lease)
            case .failure(let error):
              if case IosReceiveGrantStore.Failure.busy = error {
                reply(FlutterError(code: "receiveGrantBusy", message: "Folder is in use; try again later", details: nil))
              } else { fail() }
            }
          }
        case "release":
          guard let lease = args?["leaseId"] as? String else { fail(); return }
          receiveGrants.release(lease) { reply(nil) }
        case "listGrantedPaths":
          self.workspaceGrantQueue.async {
            do { let paths = try receiveGrants.listGrantedPaths(); DispatchQueue.main.async { reply(paths) } }
            catch { DispatchQueue.main.async { fail() } }
          }
        case "isGrantedPath":
          guard let path = args?["path"] as? String else { fail(); return }
          self.workspaceGrantQueue.async {
            do { let known = try receiveGrants.isGrantedPath(path); DispatchQueue.main.async { reply(known) } }
            catch { DispatchQueue.main.async { fail() } }
          }
        default: reply(FlutterMethodNotImplemented)
        }
      }
      let grants = IosWorkspaceGrantStore(root: support.appendingPathComponent(".legnasend-workspace-grants", isDirectory: true))
      let workspaceChannel = FlutterMethodChannel(name: "legnasend/ios_workspace", binaryMessenger: engineBridge.applicationRegistrar.messenger())
      workspaceChannel.setMethodCallHandler { [weak self] call, reply in
        guard let self = self else { reply(FlutterError(code: "unavailable", message: "Workspace authorization unavailable", details: nil)); return }
        func respond(_ work: @escaping () throws -> Any?) {
          self.workspaceGrantQueue.async {
            do { let value = try work(); DispatchQueue.main.async { reply(value) } }
            catch { DispatchQueue.main.async { reply(FlutterError(code: "grantUnavailable", message: "Select the folder again to restore access", details: nil)) } }
          }
        }
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "pick":
          self.workspacePicker.present { outcome in
            switch outcome {
            case .success(let url):
              guard let url = url else { reply(nil); return }
              respond { try grants.save(url) }
            case .failure: reply(FlutterError(code: "grantUnavailable", message: "Folder selection unavailable", details: nil))
            }
          }
        case "probe":
          guard let id = args?["grantId"] as? String else { reply(FlutterError(code: "invalid", message: "Missing grant", details: nil)); return }
          respond { try grants.probe(id) }
        case "acquire":
          guard let ids = args?["grantIds"] as? [String] else { reply(FlutterError(code: "invalid", message: "Missing grants", details: nil)); return }
          respond { try grants.acquire(ids, retaining: args?["leaseId"] as? String) }
        case "retainOnly":
          guard let lease = args?["leaseId"] as? String, let ids = args?["grantIds"] as? [String] else { reply(FlutterError(code: "invalid", message: "Missing lease", details: nil)); return }
          respond { try grants.retainOnly(lease, ids: ids) }
        case "release":
          guard let id = args?["leaseId"] as? String else { reply(FlutterError(code: "invalid", message: "Missing lease", details: nil)); return }
          respond { grants.release(id); return true }
        case "adopt":
          guard let id = args?["grantId"] as? String else { reply(FlutterError(code: "invalid", message: "Missing grant", details: nil)); return }
          respond { try grants.adopt(id); return true }
        case "prune":
          guard let ids = args?["grantIds"] as? [String] else { reply(FlutterError(code: "invalid", message: "Missing grants", details: nil)); return }
          respond { try grants.prune(ids); return true }
        case "discard":
          guard let id = args?["grantId"] as? String else { reply(FlutterError(code: "invalid", message: "Missing grant", details: nil)); return }
          respond { try grants.discard(id); return true }
        default: reply(FlutterMethodNotImplemented)
        }
      }
      let store = IosDropStore(root: support.appendingPathComponent(".legnasend-ios-drops", isDirectory: true))
      nativeDrop = IosDropInteraction(store: store,
        event: { method, arguments, reply in dropEvents.invokeMethod(method, arguments: arguments, result: reply) },
        control: { method, arguments, reply in dropControl.invokeMethod(method, arguments: arguments, result: reply) })
      dropControl.setMethodCallHandler { call, result in
        guard call.method == "clearIfIdle" else { result(FlutterMethodNotImplemented); return }
        DispatchQueue.global(qos: .utility).async {
          do {
            let cleared = try store.clearIfIdle()
            DispatchQueue.main.async { result(cleared) }
          } catch {
            DispatchQueue.main.async { result(FlutterError(code: "dropCleanup", message: "Drop cache cleanup failed", details: nil)) }
          }
        }
      }
      for notification in [UIApplication.didBecomeActiveNotification, UIWindow.didBecomeVisibleNotification] {
        dropObservers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
          self?.attachNativeDrop()
        })
      }
      DispatchQueue.main.async { [weak self] in self?.attachNativeDrop() }
    }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

import Foundation

private final class ScopeCounter {
  private let lock = NSLock()
  private var starts = 0, stops = 0, attempts = 0
  var allowed = true
  func start(_ url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; attempts += 1; guard allowed else { return false }; starts += 1; return true }
  func stop(_ url: URL) { lock.lock(); defer { lock.unlock() }; stops += 1 }
  var startAttempts: Int { lock.lock(); defer { lock.unlock() }; return attempts }
  var active: Int { lock.lock(); defer { lock.unlock() }; return starts - stops }
}

@main struct ReceiveGrantStoreTests {
  static func wait(_ signal: DispatchSemaphore) { precondition(signal.wait(timeout: .now() + 5) == .success, "Timed out waiting for actual drain") }
  static func acquire(_ store: IosReceiveGrantStore, _ path: String, maintenance: Bool = false) -> Result<[String: String]?, Error> {
    let signal = DispatchSemaphore(value: 0)
    var result: Result<[String: String]?, Error>!
    store.acquire(path, maintenance: maintenance) { result = $0; signal.signal() }
    wait(signal); return result
  }
  static func release(_ store: IosReceiveGrantStore, _ id: String) {
    let signal = DispatchSemaphore(value: 0)
    store.release(id) { signal.signal() }; wait(signal)
  }
  static func expectFailure(_ result: Result<[String: String]?, Error>, line: UInt = #line) {
    if case .success = result { fatalError("Expected rejected path or stale grant at line \(line)") }
  }
  static func expectBusy(_ result: Result<[String: String]?, Error>) {
    guard case .failure(let error) = result, case IosReceiveGrantStore.Failure.busy = error else { fatalError("Expected immediate overlap busy") }
  }
  static func check(_ value: @autoclosure () throws -> Bool) rethrows { let result = try value(); precondition(result) }
  static func main() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: base) }
    let directory = base.appendingPathComponent("提供器 空格 %", isDirectory: true)
    let other = base.appendingPathComponent("other", isDirectory: true)
    let documents = base.appendingPathComponent("sandbox/Documents", isDirectory: true)
    for root in [directory, other, documents] { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
    let storage = base.appendingPathComponent("receive-grants", isDirectory: true)
    let counter = ScopeCounter()
    let grants = IosWorkspaceGrantStore(root: storage.appendingPathComponent("bookmarks"), start: counter.start, stop: counter.stop)
    let callbacks = DispatchQueue(label: "receive-tests.callbacks")
    let store = IosReceiveGrantStore(root: storage, grants: grants, sandboxRoots: [documents], callbackQueue: callbacks,
      coordinate: { url, _, accessor in accessor(url) })
    try check(store.listGrantedPaths().isEmpty)
    let path = try store.save(directory)
    precondition(path == directory.path && counter.active == 0)
    try check(store.isGrantedPath(path))
    try check(store.listGrantedPaths() == [path])
    _ = try store.save(directory)
    try check(store.listGrantedPaths() == [path]) // Re-selection is not a second root.
    try check(!store.isGrantedPath(other.path))
    expectFailure(acquire(store, other.path))
    expectFailure(acquire(store, path + "/unapproved-child"))
    expectFailure(acquire(store, "relative"))
    let sandbox = try acquire(store, documents.appendingPathComponent("Downloads/not-created").path).get()
    precondition(sandbox == nil && counter.active == 0)
    try fm.createSymbolicLink(at: documents.appendingPathComponent("escape"), withDestinationURL: other)
    expectFailure(acquire(store, documents.appendingPathComponent("escape/subdir").path))

    let lease = try acquire(store, path).get()!
    precondition(lease["path"] == path && counter.active == 1)
    try Data("transfer bytes".utf8).write(to: directory.appendingPathComponent("new.bin"))
    release(store, lease["leaseId"]!)
    precondition(counter.active == 0)
    release(store, lease["leaseId"]!) // Repeat does not double-stop.

    // Coordinator exit, not merely signaling its accessor, fences scope release.
    let afterAccessor = DispatchSemaphore(value: 0), allowExit = DispatchSemaphore(value: 0)
    let slow = IosReceiveGrantStore(root: storage, grants: grants, sandboxRoots: [], callbackQueue: callbacks,
      coordinate: { url, _, accessor in accessor(url); afterAccessor.signal(); wait(allowExit) })
    let slowLease = try acquire(slow, path).get()!
    let released = DispatchSemaphore(value: 0)
    slow.release(slowLease["leaseId"]!) { released.signal() }
    wait(afterAccessor)
    precondition(counter.active == 1)
    precondition(released.wait(timeout: .now() + 0.03) == .timedOut)
    allowExit.signal(); wait(released)
    precondition(counter.active == 0)

    // Restart resolves saved bookmark bytes and index, not in-memory selected URLs.
    let reopenedGrants = IosWorkspaceGrantStore(root: storage.appendingPathComponent("bookmarks"), start: counter.start, stop: counter.stop)
    let reopened = IosReceiveGrantStore(root: storage, grants: reopenedGrants, sandboxRoots: [], callbackQueue: callbacks,
      coordinate: { url, _, accessor in accessor(url) })
    let realCoordinator = IosReceiveGrantStore(root: storage, grants: reopenedGrants, sandboxRoots: [], callbackQueue: callbacks)
    let coordinated = try acquire(realCoordinator, path).get()!
    precondition(counter.active == 1)
    try Data("coordinated write".utf8).write(to: directory.appendingPathComponent("coordinated.bin"))
    release(realCoordinator, coordinated["leaseId"]!)
    precondition(counter.active == 0)
    let restored = try acquire(reopened, path).get()!
    release(reopened, restored["leaseId"]!)
    counter.allowed = false
    let attemptsBeforeListing = counter.startAttempts
    try check(reopened.listGrantedPaths() == [path])
    precondition(counter.startAttempts == attemptsBeforeListing) // No bookmark/provider access.
    expectFailure(acquire(reopened, path))
    try check(reopened.isGrantedPath(path)) // Revocation never makes it a sandbox path.
    counter.allowed = true
    precondition(counter.active == 0)
    // A missing approved directory stays marked granted, but never receives a lease.
    let missing = try store.save(other)
    try fm.removeItem(at: other)
    expectFailure(acquire(reopened, missing))
    try check(reopened.isGrantedPath(missing))
    try check(reopened.listGrantedPaths() == [path, missing].sorted())
    try fm.createDirectory(at: other, withIntermediateDirectories: true)
    _ = try store.save(other) // Explicit re-selection after recreation renews its bookmark.

    let moved = IosReceiveGrantStore(root: storage, grants: reopenedGrants, sandboxRoots: [], callbackQueue: callbacks,
      coordinate: { _, _, accessor in accessor(other) })
    expectFailure(acquire(moved, path)); precondition(counter.active == 0)
    let denied = IosReceiveGrantStore(root: storage, grants: reopenedGrants, sandboxRoots: [], callbackQueue: callbacks,
      coordinate: { _, _, _ in throw IosReceiveGrantStore.Failure.coordination })
    expectFailure(acquire(denied, path)); precondition(counter.active == 0)

    // Four active requests consume the whole budget; release uses another queue.
    var leases: [String] = []
    for _ in 0..<4 { leases.append(try acquire(reopened, path).get()!["leaseId"]!) }
    expectFailure(acquire(reopened, path))
    for id in leases { release(reopened, id) }
    precondition(counter.active == 0)

    // Maintenance never queues behind our own root or descendant accessor.
    let child = directory.appendingPathComponent("child", isDirectory: true)
    try fm.createDirectory(at: child, withIntermediateDirectories: true)
    let childPath = try store.save(child)
    let receiving = try acquire(reopened, path).get()!
    expectBusy(acquire(reopened, path, maintenance: true))
    expectBusy(acquire(reopened, path.uppercased(), maintenance: true))
    expectBusy(acquire(reopened, childPath, maintenance: true))
    let independent = try acquire(reopened, missing, maintenance: true).get()!
    release(reopened, independent["leaseId"]!)
    release(reopened, receiving["leaseId"]!)
    let maintaining = try acquire(reopened, childPath, maintenance: true).get()!
    expectBusy(acquire(reopened, path))
    expectBusy(acquire(reopened, childPath))
    expectBusy(acquire(reopened, path, maintenance: true))
    release(reopened, maintaining["leaseId"]!)
    precondition(counter.active == 0)

    // Queued coordination reserves overlap before its accessor is entered.
    // Cancellation never hands a naked URL to the caller or prematurely drops scope.
    for maintenance in [false, true] {
      let entered = DispatchSemaphore(value: 0), ready = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0)
      let pending = IosReceiveGrantStore(root: storage, grants: reopenedGrants, sandboxRoots: [], callbackQueue: callbacks,
        coordinate: { url, _, accessor in entered.signal(); wait(ready); accessor(url) })
      let token = pending.acquire(path, maintenance: maintenance) { result in expectFailure(result); cancelled.signal() }
      wait(entered)
      expectBusy(acquire(pending, childPath, maintenance: !maintenance))
      let drained = DispatchSemaphore(value: 0)
      pending.release(token) { drained.signal() }
      ready.signal(); wait(cancelled); wait(drained)
      precondition(counter.active == 0)
    }
    // Index bounds are validated without opening any stored provider path.
    let indexURL = storage.appendingPathComponent("paths.json")
    let originalIndex = try Data(contentsOf: indexURL)
    let oversized = Dictionary(uniqueKeysWithValues: (0..<129).map { ("/unopened/provider/\($0)", UUID().uuidString.lowercased()) })
    try JSONSerialization.data(withJSONObject: oversized).write(to: indexURL, options: .atomic)
    do { _ = try reopened.listGrantedPaths(); fatalError("Accepted oversized index") } catch {}
    try originalIndex.write(to: indexURL, options: .atomic)
    try check(reopened.listGrantedPaths() == [path, childPath, missing].sorted())
    print("PASS: bounded private root enumeration, no provider/scope access, revoked and missing roots retained, bidirectional maintenance overlap exclusion")
    print("PASS: receive bookmark persistence, exact authorization, sandbox escape rejection, held coordination/scope, real release fence, revocation, redirected roots, four-session bound, cancellation")
  }
}

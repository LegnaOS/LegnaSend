import Foundation

/// Independent receive-only bookmarks and exact approved-path index. A path is
/// not a capability: only the picker can add it to this private index.
final class IosReceiveGrantStore {
  enum Failure: Error { case invalidPath, unapproved, changedRoot, busy, cancelled, coordination }
  typealias Coordinate = (URL, NSFileCoordinator, @escaping (URL) -> Void) throws -> Void
  private final class Job {
    let id = UUID().uuidString.lowercased()
    let path: String
    let maintenance: Bool
    let coordinator = NSFileCoordinator(filePresenter: nil)
    let stop = DispatchSemaphore(value: 0)
    let completion: (Result<[String: String]?, Error>) -> Void
    var replied = false
    var releasing = false
    var releaseReplies: [() -> Void] = []
    init(path: String, maintenance: Bool, completion: @escaping (Result<[String: String]?, Error>) -> Void) {
      self.path = path; self.maintenance = maintenance; self.completion = completion
    }
  }
  private let root: URL
  private let grants: IosWorkspaceGrantStore
  private let sandboxRoots: [URL]
  private let coordinate: Coordinate
  private let callbackQueue: DispatchQueue
  private let control = DispatchQueue(label: "legnasend.receive-grants.control")
  private let workers: OperationQueue = {
    let queue = OperationQueue(); queue.name = "legnasend.receive-grants.coordination"
    queue.maxConcurrentOperationCount = 4; queue.qualityOfService = .userInitiated; return queue
  }()
  private let indexLock = NSRecursiveLock()
  private var jobs: [String: Job] = [:] // accessed only by control
  private let manager = FileManager.default

  init(root: URL, grants: IosWorkspaceGrantStore? = nil, sandboxRoots: [URL]? = nil,
       callbackQueue: DispatchQueue = .main, coordinate: Coordinate? = nil) {
    self.root = root
    self.grants = grants ?? IosWorkspaceGrantStore(root: root.appendingPathComponent("bookmarks", isDirectory: true))
    self.sandboxRoots = sandboxRoots ?? [.documentDirectory, .libraryDirectory].compactMap {
      FileManager.default.urls(for: $0, in: .userDomainMask).first
    }
    self.callbackQueue = callbackQueue
    self.coordinate = coordinate ?? { url, coordinator, accessor in
      var error: NSError?
      coordinator.coordinate(writingItemAt: url, options: [], error: &error, byAccessor: accessor)
      if let error = error { throw error }
    }
  }

  private func validPath(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 32768
  }
  /// Nonexistent Downloads descendants are valid only below the application's
  /// actual Documents/Library roots; resolving existing parents catches escapes.
  private func sandboxPath(_ path: String) -> Bool {
    guard validPath(path), !path.split(separator: "/").contains("..") else { return false }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    return sandboxRoots.contains { root in
      let lexical = root.standardizedFileURL.path
      let resolved = root.resolvingSymlinksInPath().path
      func inside(_ value: String, _ parent: String) -> Bool { value == parent || value.hasPrefix(parent + "/") }
      // This runs on the release control queue. Reject external paths by
      // string prefix before any candidate filesystem lookup can reach a provider.
      guard inside(url.path, lexical) || inside(url.path, resolved) else { return false }
      let matched = inside(url.path, lexical) ? lexical : resolved
      // Foundation may leave symlinks unresolved when the final child does not
      // exist yet. Inspect every existing parent, including dangling symlinks.
      var parent = URL(fileURLWithPath: matched, isDirectory: true)
      for component in url.path.dropFirst(matched.count).split(separator: "/") {
        parent.appendPathComponent(String(component))
        if (try? manager.destinationOfSymbolicLink(atPath: parent.path)) != nil { return false }
      }
      // Parent checks above also prevent following an escaping provider symlink.
      return inside(url.resolvingSymlinksInPath().path, resolved)
    }
  }
  private func indexURL() throws -> URL {
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true && values.isSymbolicLink != true else { throw Failure.invalidPath }
    var url = root; var flags = URLResourceValues(); flags.isExcludedFromBackup = true
    try url.setResourceValues(flags)
    return root.appendingPathComponent("paths.json")
  }
  private func readIndex() throws -> [String: String] {
    let url = try indexURL()
    guard manager.fileExists(atPath: url.path) else { return [:] }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true && values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 1024 * 1024,
          let index = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String], index.count <= 128,
          index.allSatisfy({ validPath($0.key) && UUID(uuidString: $0.value)?.uuidString.lowercased() == $0.value }) else { throw Failure.invalidPath }
    return index
  }
  func save(_ url: URL) throws -> String {
    guard url.isFileURL else { throw Failure.invalidPath }
    if sandboxPath(url.path) { return url.resolvingSymlinksInPath().path }
    indexLock.lock(); defer { indexLock.unlock() }
    var index = try readIndex()
    let saved = try grants.save(url)
    guard let path = saved["locator"], let id = saved["grantId"] else { throw Failure.invalidPath }
    do {
      guard index[path] != nil || index.count < 128 else { throw Failure.busy }
      index[path] = id
      // Adopt first; an interrupted atomic index write leaves only an unindexed
      // private bookmark, never authority for an arbitrary path.
      try grants.adopt(id)
      try JSONSerialization.data(withJSONObject: index).write(to: indexURL(), options: .atomic)
    } catch { try? grants.discard(id); throw error }
    try? grants.prune(Array(index.values))
    return path
  }
  func isGrantedPath(_ path: String) throws -> Bool {
    guard validPath(path) else { return false }
    indexLock.lock(); defer { indexLock.unlock() }
    // Revocation does not erase this marker and accidentally enable bare-path fallback.
    return try readIndex()[path] != nil
  }
  /// Private index snapshot only: do not resolve bookmarks, canonicalize the
  /// saved external paths or contact providers while discovering cleanup roots.
  func listGrantedPaths() throws -> [String] {
    indexLock.lock(); defer { indexLock.unlock() }
    return try readIndex().keys.sorted() // Dictionary keys are unique; readIndex enforces <= 128.
  }
  private func overlaps(_ left: String, _ right: String) -> Bool {
    func key(_ path: String) -> String {
      URL(fileURLWithPath: path).standardizedFileURL.path.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    let a = key(left), b = key(right)
    return a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/") || b.hasPrefix(a.hasSuffix("/") ? a : a + "/")
  }
  private func grantId(_ path: String) throws -> String {
    guard validPath(path) else { throw Failure.invalidPath }
    indexLock.lock(); defer { indexLock.unlock() }
    guard let id = try readIndex()[path] else { throw Failure.unapproved }
    return id
  }

  /// A maximum of four active/pending sessions includes provider-blocked work.
  /// Callback nil is reserved for confirmed app-owned sandbox directories.
  @discardableResult
  func acquire(_ path: String, maintenance: Bool = false, completion: @escaping (Result<[String: String]?, Error>) -> Void) -> String {
    let job = Job(path: path, maintenance: maintenance, completion: completion)
    control.async {
      if self.sandboxPath(path) { self.callbackQueue.async { completion(.success(nil)) }; return }
      guard self.jobs.count < 4 else { self.callbackQueue.async { completion(.failure(Failure.busy)) }; return }
      // Reserve maintenance admission before queueing coordination. Never wait
      // on an app-owned overlapping accessor which may itself need this caller.
      guard !self.jobs.values.contains(where: { (maintenance || $0.maintenance) && self.overlaps(path, $0.path) }) else {
        self.callbackQueue.async { completion(.failure(Failure.busy)) }; return
      }
      self.jobs[job.id] = job
      self.workers.addOperation { self.run(job) }
    }
    return job.id
  }
  private func run(_ job: Job) {
    var grantLease: String?
    var failure: Error = Failure.coordination
    do {
      let id = try grantId(job.path)
      let held = try grants.acquire([id])
      guard let lease = held["leaseId"] as? String else { throw Failure.coordination }
      grantLease = lease
      guard let roots = held["roots"] as? [String: String], roots[id] == job.path else { throw Failure.changedRoot }
      if control.sync(execute: { job.releasing }) { throw Failure.cancelled }
      var accessorError: Error?
      try coordinate(URL(fileURLWithPath: job.path, isDirectory: true), job.coordinator) { url in
        do {
          let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          guard url.isFileURL && values.isDirectory == true && values.isSymbolicLink != true,
                url.resolvingSymlinksInPath().path == job.path else { throw Failure.changedRoot }
          let ready = self.control.sync { () -> Bool in
            guard !job.releasing else { return false }
            job.replied = true; return true
          }
          guard ready else { throw Failure.cancelled }
          self.callbackQueue.async { job.completion(.success(["leaseId": job.id, "path": job.path])) }
          // Only an explicit release after Dart's actual core drain ends access.
          job.stop.wait()
        } catch { accessorError = error }
      }
      if let error = accessorError { throw error }
    } catch { failure = error }
    // Coordinate has really returned before balancing scope or acknowledging release.
    if let lease = grantLease { grants.release(lease) }
    let error = failure
    control.async {
      self.jobs.removeValue(forKey: job.id)
      if !job.replied { self.callbackQueue.async { job.completion(.failure(error)) } }
      for callback in job.releaseReplies { self.callbackQueue.async(execute: callback) }
    }
  }
  /// Control never waits on a coordinator worker. Completion is posted only
  /// once the writing accessor and security scope have both fully drained.
  func release(_ id: String, completion: @escaping () -> Void) {
    control.async {
      guard let job = self.jobs[id] else { self.callbackQueue.async(execute: completion); return }
      job.releaseReplies.append(completion)
      if !job.releasing {
        job.releasing = true
        job.stop.signal()
        if !job.replied { job.coordinator.cancel() }
      }
    }
  }
}

import Foundation

/// Private bookmark capabilities. A probe never outlives its scope; publication
/// leases keep the scope alive until the corresponding server acknowledgement.
final class IosWorkspaceGrantStore {
  enum Failure: Error { case invalidGrant, denied, unsafeRoot, capacity }
  private let root: URL
  private let manager = FileManager.default
  private let lock = NSRecursiveLock()
  private let start: (URL) -> Bool
  private let stop: (URL) -> Void
  private var resources: [String: (URL, Int)] = [:]
  private var leases: [String: [String]] = [:]
  private var pending = Set<String>()
  private let maxGrants = 128

  init(root: URL, start: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
       stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
    self.root = root; self.start = start; self.stop = stop
  }
  private func directory(_ url: URL) throws {
    guard url.isFileURL else { throw Failure.unsafeRoot }
    let value = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard value.isDirectory == true && value.isSymbolicLink != true else { throw Failure.unsafeRoot }
  }
  private func privateRoot() throws {
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try directory(root)
    var url = root; var flags = URLResourceValues(); flags.isExcludedFromBackup = true
    try url.setResourceValues(flags)
  }
  private func file(_ id: String) throws -> URL {
    guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else { throw Failure.invalidGrant }
    return root.appendingPathComponent(id + ".bookmark")
  }
  private func inspect(_ url: URL) throws -> String {
    try directory(url)
    var error: Error?
    guard let iterator = manager.enumerator(at: url, includingPropertiesForKeys: [], options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants], errorHandler: { _, issue in error = issue; return false }) else { throw Failure.denied }
    _ = iterator.nextObject() // A shallow, lazy permission check, never a tree copy.
    if let error = error { throw error }
    return url.resolvingSymlinksInPath().path
  }
  private func resolve(_ id: String) throws -> URL {
    try privateRoot()
    let path = try file(id)
    let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true && values.isSymbolicLink != true,
          let size = values.fileSize, size > 0 && size <= 1024 * 1024 else { throw Failure.invalidGrant }
    let data = try Data(contentsOf: path)
    var stale = false
    #if os(macOS)
    let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
    let options: URL.BookmarkResolutionOptions = [.withoutUI]
    #endif
    let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
    guard url.isFileURL else { throw Failure.unsafeRoot }
    // A stale grant requires an explicit user re-selection. Never silently bind
    // an old public workspace to a relocated/replaced folder.
    guard !stale else { throw Failure.invalidGrant }
    return url
  }
  func save(_ url: URL) throws -> [String: String] {
    lock.lock(); defer { lock.unlock() }
    try privateRoot()
    let files = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    guard files.filter({ $0.pathExtension == "bookmark" }).count < maxGrants else { throw Failure.capacity }
    guard start(url) else { throw Failure.denied }
    defer { stop(url) }
    let path = try inspect(url)
    #if os(macOS)
    // macOS app-sandbox authority must survive process restart. A minimal
    // bookmark remembers a location but is not a persisted sandbox capability.
    let options: URL.BookmarkCreationOptions = [.withSecurityScope]
    #else
    let options: URL.BookmarkCreationOptions = [.minimalBookmark]
    #endif
    let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    guard !data.isEmpty && data.count <= 1024 * 1024 else { throw Failure.invalidGrant }
    let id = UUID().uuidString.lowercased()
    try data.write(to: file(id), options: [.withoutOverwriting])
    pending.insert(id)
    return ["grantId": id, "locator": path]
  }
  func probe(_ id: String) throws -> String {
    lock.lock(); defer { lock.unlock() }
    let url = try resolve(id)
    guard start(url) else { throw Failure.denied }
    defer { stop(url) }
    return try inspect(url)
  }
  func acquire(_ ids: [String], retaining lease: String? = nil) throws -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    guard ids.count <= maxGrants && Set(ids).count == ids.count && leases.count < 256 else { throw Failure.capacity }
    let previous: [String]
    if let lease = lease { guard let stored = leases[lease] else { throw Failure.invalidGrant }; previous = stored }
    else { previous = [] }
    var acquired: [String] = []; var paths: [String: String] = [:]
    for id in previous { if let resource = resources[id] { paths[id] = resource.0.resolvingSymlinksInPath().path } }
    do {
      for id in ids {
        if previous.contains(id) { guard let resource = resources[id] else { throw Failure.invalidGrant }; paths[id] = try inspect(resource.0); continue }
        if let resource = resources[id] {
          paths[id] = try inspect(resource.0)
          resources[id] = (resource.0, resource.1 + 1)
        } else {
          let url = try resolve(id)
          guard start(url) else { throw Failure.denied }
          do { paths[id] = try inspect(url) } catch { stop(url); throw error }
          resources[id] = (url, 1)
        }
        acquired.append(id)
      }
      let identifier = lease ?? UUID().uuidString.lowercased()
      leases[identifier] = previous + acquired
      return ["leaseId": identifier, "roots": paths]
    } catch {
      releaseResources(acquired)
      throw error
    }
  }
  /// Called only after an exact server configuration acknowledgement. Before
  /// acknowledgement, acquire extends this one lease and never drops old roots.
  func retainOnly(_ lease: String, ids: [String]) throws -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    guard let previous = leases[lease], Set(ids).isSubset(of: Set(previous)) else { throw Failure.invalidGrant }
    let keep = Array(Set(ids)).sorted()
    releaseResources(previous.filter { !keep.contains($0) })
    leases[lease] = keep
    let paths = Dictionary(uniqueKeysWithValues: keep.compactMap { id -> (String, String)? in
      guard let value = resources[id] else { return nil }; return (id, value.0.resolvingSymlinksInPath().path)
    })
    return ["leaseId": lease, "roots": paths]
  }
  private func releaseResources(_ ids: [String]) {
    for id in ids {
      guard let resource = resources[id] else { continue }
      if resource.1 == 1 { resources.removeValue(forKey: id); stop(resource.0) }
      else { resources[id] = (resource.0, resource.1 - 1) }
    }
  }
  func release(_ lease: String) {
    lock.lock(); defer { lock.unlock() }
    if let ids = leases.removeValue(forKey: lease) { releaseResources(ids) }
  }
  func adopt(_ id: String) throws {
    lock.lock(); defer { lock.unlock() }
    _ = try resolve(id); pending.remove(id)
  }
  func prune(_ keeping: [String]) throws {
    lock.lock(); defer { lock.unlock() }
    try privateRoot()
    let keep = Set(keeping)
    for path in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where path.pathExtension == "bookmark" {
      let id = path.deletingPathExtension().lastPathComponent
      guard !keep.contains(id) && !pending.contains(id) && resources[id] == nil else { continue }
      // Strict UUID and regular-file validation applies before any deletion.
      try discard(id)
    }
  }
  func discard(_ id: String) throws {
    lock.lock(); defer { lock.unlock() }
    guard resources[id] == nil else { throw Failure.denied }
    let path = try file(id)
    if manager.fileExists(atPath: path.path) {
      let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true && values.isSymbolicLink != true else { throw Failure.invalidGrant }
      try manager.removeItem(at: path)
    }
    pending.remove(id)
  }
}

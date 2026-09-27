import Foundation

/// Owns only copied drop batches, never the external provider's source paths.
final class IosDropStore {
  enum Failure: Error { case unsafeSource, invalidBatch }
  private let root: URL
  private let lock = NSRecursiveLock()
  private var active = Set<String>()
  private let marker = Data("LegnaSend iOS drop v1\n".utf8)
  private let manager = FileManager.default

  init(root: URL) { self.root = root }

  private func directory(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true && values.isSymbolicLink != true else { throw Failure.unsafeSource }
  }

  func begin() throws -> URL {
    lock.lock(); defer { lock.unlock() }
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try directory(root)
    let batch = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: batch, withIntermediateDirectories: false)
    do {
      try marker.write(to: batch.appendingPathComponent(".owner"), options: .atomic)
      var excluded = batch
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try excluded.setResourceValues(values)
    } catch {
      try? manager.removeItem(at: batch)
      throw error
    }
    active.insert(batch.lastPathComponent)
    return batch
  }

  private func validateTree(_ source: URL) throws {
    guard source.isFileURL else { throw Failure.unsafeSource }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
    func check(_ url: URL) throws -> Bool {
      let value = try url.resourceValues(forKeys: keys)
      guard value.isSymbolicLink != true && (value.isRegularFile == true || value.isDirectory == true) else { throw Failure.unsafeSource }
      return value.isDirectory == true
    }
    if try check(source) {
      var enumerationError: Error?
      guard let entries = manager.enumerator(at: source, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
        enumerationError = error
        return false
      }) else { throw Failure.unsafeSource }
      for case let entry as URL in entries { _ = try check(entry) }
      if let error = enumerationError { throw error }
    }
  }

  func copy(source: URL, suggestedName: String?, index: Int, batch: URL) throws -> URL {
    lock.lock()
    let owned = active.contains(batch.lastPathComponent) && batch.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
    lock.unlock()
    guard owned else { throw Failure.invalidBatch }
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    try validateTree(source)
    let proposed = suggestedName ?? source.lastPathComponent
    let safe = !proposed.isEmpty && proposed != "." && proposed != ".." && !proposed.contains("/") && !proposed.contains("\\") && !proposed.contains("\0")
    var name = safe ? proposed : source.lastPathComponent
    // Photos commonly supplies a display basename while its exported file URL
    // carries the actual encoding suffix. Keep that suffix for type detection.
    let regular = try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    if (name as NSString).pathExtension.isEmpty && !source.pathExtension.isEmpty && regular {
      name += "." + source.pathExtension
    }
    guard !name.isEmpty && name != "." && name != ".." else { throw Failure.unsafeSource }
    // Separate item parents preserve equal basenames without overwriting them.
    let parent = batch.appendingPathComponent("item-\(index)", isDirectory: true)
    try manager.createDirectory(at: parent, withIntermediateDirectories: false)
    let destination = parent.appendingPathComponent(name)
    try manager.copyItem(at: source, to: destination)
    try validateTree(destination)
    return destination
  }

  func finish(_ batch: URL, keep: Bool) {
    lock.lock(); defer { lock.unlock() }
    guard active.remove(batch.lastPathComponent) != nil else { return }
    if !keep { try? manager.removeItem(at: batch) }
  }

  /// The Dart caller also holds the source-cache cleanup lease. Native imports
  /// reserve their batch before async loading, covering the pre-Dart window.
  func clearIfIdle() throws -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard active.isEmpty else { return false }
    guard manager.fileExists(atPath: root.path) else { return true }
    try directory(root)
    for batch in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
      guard UUID(uuidString: batch.lastPathComponent) != nil else { continue }
      try directory(batch)
      let owner = batch.appendingPathComponent(".owner")
      let value = try owner.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard value.isRegularFile == true && value.isSymbolicLink != true else { continue }
      guard try Data(contentsOf: owner) == marker else { continue }
      try manager.removeItem(at: batch)
    }
    return true
  }
}

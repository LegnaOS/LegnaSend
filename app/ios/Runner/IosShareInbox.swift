import Foundation

/// Per-request manifests avoid overwriting an earlier, still queued share.
/// Acknowledgement removes only the manifest; selected files remain immutable.
final class IosShareInbox {
  enum Failure: Error { case invalidBatch, invalidManifest }
  let root: URL
  init(root: URL) { self.root = root }
  private func batch(_ id: String) throws -> URL {
    guard UUID(uuidString: id)?.uuidString == id else { throw Failure.invalidBatch }
    return root.appendingPathComponent(id, isDirectory: true)
  }
  func publish(batch: URL, attachments: [[String: Any]], text: [String]) throws {
    guard batch.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
          try self.batch(batch.lastPathComponent).standardizedFileURL == batch.standardizedFileURL,
          attachments.count <= 999, text.count <= 999 else { throw Failure.invalidBatch }
    let payload: [String: Any] = ["batchId": batch.lastPathComponent, "attachments": attachments, "content": text.joined(separator: "\n")]
    let data = try JSONSerialization.data(withJSONObject: payload)
    guard data.count <= 4 * 1024 * 1024 else { throw Failure.invalidManifest }
    try data.write(to: batch.appendingPathComponent("pending.json"), options: .atomic)
  }
  func next() throws -> [String: Any]? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: root.path) else { return nil }
    let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
    var folders: [(URL, Date)] = entries.map { folder in
      let values = try? folder.resourceValues(forKeys: [.creationDateKey])
      return (folder, values?.creationDate ?? Date.distantPast)
    }
    folders.sort { left, right in
      if left.1 == right.1 { return left.0.lastPathComponent < right.0.lastPathComponent }
      return left.1 < right.1
    }
    for (folder, _) in folders {
      guard UUID(uuidString: folder.lastPathComponent)?.uuidString == folder.lastPathComponent else { continue }
      let attributes = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard attributes.isDirectory == true && attributes.isSymbolicLink != true else { continue }
      let manifest = folder.appendingPathComponent("pending.json")
      guard fm.fileExists(atPath: manifest.path) else { continue }
      let values = try manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4 * 1024 * 1024,
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
            value["batchId"] as? String == folder.lastPathComponent,
            let files = value["attachments"] as? [[String: Any]], files.count <= 999,
            value["content"] is String else { throw Failure.invalidManifest }
      for file in files {
        guard let path = file["path"] as? String, path.hasPrefix("/"),
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"),
              let type = file["type"] as? Int, (0...3).contains(type) else { throw Failure.invalidManifest }
        let source = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard source.isRegularFile == true && source.isSymbolicLink != true else { throw Failure.invalidManifest }
      }
      return value
    }
    return nil
  }
  func acknowledge(_ id: String) throws {
    let folder = try batch(id)
    let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true && values.isSymbolicLink != true else { throw Failure.invalidBatch }
    let manifest = folder.appendingPathComponent("pending.json")
    if FileManager.default.fileExists(atPath: manifest.path) { try FileManager.default.removeItem(at: manifest) }
  }
}

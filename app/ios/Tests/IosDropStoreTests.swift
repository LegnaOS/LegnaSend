import Foundation

@main
struct IosDropStoreTests {
  static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: message, code: 1) }
  }
  static func main() throws {
    let manager = FileManager.default
    let temp = manager.temporaryDirectory.appendingPathComponent("legnasend-ios-drop-\(UUID().uuidString)")
    try manager.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: temp) }
    let source = temp.appendingPathComponent("用户目录", isDirectory: true)
    try manager.createDirectory(at: source.appendingPathComponent("子目录"), withIntermediateDirectories: true)
    let original = source.appendingPathComponent("子目录/文本.txt")
    let bytes = Data("原文件\u{0}\n".utf8)
    try bytes.write(to: original)
    let root = temp.appendingPathComponent("private-drops")
    let store = IosDropStore(root: root)
    let batch = try store.begin()
    let first = try store.copy(source: source, suggestedName: "用户目录", index: 0, batch: batch)
    let second = try store.copy(source: source, suggestedName: "用户目录", index: 1, batch: batch)
    let named = try store.copy(source: original, suggestedName: "display-name", index: 2, batch: batch)
    try require(named.lastPathComponent == "display-name.txt", "provider basename retains exported encoding suffix")
    try require(first != second, "equal names must not overwrite")
    try require(try Data(contentsOf: first.appendingPathComponent("子目录/文本.txt")) == bytes, "relative directory content")
    try require(try !store.clearIfIdle(), "live import blocks cache cleanup")
    try require(manager.fileExists(atPath: first.path), "live imported source survives cleanup")
    store.finish(batch, keep: true)
    try require(manager.fileExists(atPath: second.path), "committed source persists")
    let foreign = root.appendingPathComponent("foreign-user-content")
    try bytes.write(to: foreign)
    try require(try store.clearIfIdle(), "idle cleanup completes")
    try require(!manager.fileExists(atPath: batch.path), "owned batch removed")
    try require(try Data(contentsOf: original) == bytes, "external source never deleted")
    try require(try Data(contentsOf: foreign) == bytes, "unowned cache entry retained")
    print("PASS ownership, duplicate names, relative paths, active lease, idle cleanup")

    let rollback = try store.begin()
    _ = try store.copy(source: original, suggestedName: "file.txt", index: 0, batch: rollback)
    let link = temp.appendingPathComponent("external-link")
    try manager.createSymbolicLink(at: link, withDestinationURL: source)
    do {
      _ = try store.copy(source: link, suggestedName: "link", index: 1, batch: rollback)
      throw NSError(domain: "symlink unexpectedly accepted", code: 1)
    } catch IosDropStore.Failure.unsafeSource { }
    store.finish(rollback, keep: false)
    try require(!manager.fileExists(atPath: rollback.path), "failed batch wholly rolled back")
    try require(try Data(contentsOf: original) == bytes, "rollback never follows source symlink")
    print("PASS whole-batch rollback and symlink rejection")

    let many = temp.appendingPathComponent("5000-files")
    try manager.createDirectory(at: many, withIntermediateDirectories: true)
    for index in 0..<5000 { try Data("\(index)".utf8).write(to: many.appendingPathComponent("\(index).txt")) }
    let bigBatch = try store.begin()
    let imported = try store.copy(source: many, suggestedName: "5000-files", index: 0, batch: bigBatch)
    try require(try manager.contentsOfDirectory(atPath: imported.path).count == 5000, "all small files preserved")
    try require(try Data(contentsOf: imported.appendingPathComponent("4999.txt")) == Data("4999".utf8), "last file content")
    store.finish(bigBatch, keep: false)
    try require(try manager.contentsOfDirectory(atPath: many.path).count == 5000, "source directory preserved")
    print("PASS 5000-file directory copy without archive or full-memory aggregation")

    let unsafeRoot = temp.appendingPathComponent("unsafe-root")
    try manager.createSymbolicLink(at: unsafeRoot, withDestinationURL: source)
    do {
      _ = try IosDropStore(root: unsafeRoot).begin()
      throw NSError(domain: "symlink root unexpectedly accepted", code: 1)
    } catch IosDropStore.Failure.unsafeSource { }
    print("PASS symlink root rejected")
  }
}

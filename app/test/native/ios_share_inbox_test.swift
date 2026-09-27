import Foundation

@main struct ShareInboxTests {
  static func main() throws {
    func check(_ value: @autoclosure () throws -> Bool) rethrows { let result = try value(); assert(result) }
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let root = base.appendingPathComponent("inbox")
    let input = base.appendingPathComponent("source")
    try fm.createDirectory(at: input, withIntermediateDirectories: true)
    let source = input.appendingPathComponent("中文 100%.txt")
    try Data("first".utf8).write(to: source)
    let store = IosDropStore(root: root), inbox = IosShareInbox(root: root)
    let one = try store.begin()
    let first = try store.copy(source: source, suggestedName: nil, index: 0, batch: one)
    try check(inbox.next() == nil)
    try inbox.publish(batch: one, attachments: [["path": first.path, "type": 3]], text: ["hello"])
    store.finish(one, keep: true)
    let next = try inbox.next()!
    assert(next["batchId"] as? String == one.lastPathComponent)
    assert((next["attachments"] as? [[String: Any]])?.first?["path"] as? String == first.path)
    let two = try store.begin()
    try Data("second".utf8).write(to: source)
    let second = try store.copy(source: source, suggestedName: nil, index: 0, batch: two)
    try check(Data(contentsOf: first) == Data("first".utf8))
    try check(Data(contentsOf: second) == Data("second".utf8))
    try inbox.publish(batch: two, attachments: [["path": second.path, "type": 3]], text: [])
    store.finish(two, keep: true)
    try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: one.path)
    try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: two.path)
    let oldest = try inbox.next()!
    assert(oldest["batchId"] as? String == one.lastPathComponent, "Creation order must beat random UUID order")
    let cancelled = try store.begin()
    _ = try store.copy(source: source, suggestedName: nil, index: 0, batch: cancelled)
    store.finish(cancelled, keep: false)
    assert(!fm.fileExists(atPath: cancelled.path))
    assert(fm.fileExists(atPath: first.path))
    let restored = IosShareInbox(root: root)
    try check(restored.next() != nil)
    try restored.acknowledge(one.lastPathComponent)
    try restored.acknowledge(one.lastPathComponent)
    let remaining = try restored.next()!
    assert(remaining["batchId"] as? String == two.lastPathComponent)
    try restored.acknowledge(two.lastPathComponent)
    try check(restored.next() == nil)
    assert(fm.fileExists(atPath: first.path), "Acknowledgement must preserve selected files")
    do { try restored.acknowledge("../source"); fatalError("accepted traversal") } catch {}
    let missing = try store.begin()
    let missingFile = try store.copy(source: source, suggestedName: nil, index: 0, batch: missing)
    try inbox.publish(batch: missing, attachments: [["path": missingFile.path, "type": 3]], text: [])
    store.finish(missing, keep: true)
    try fm.removeItem(at: missingFile)
    do { _ = try restored.next(); fatalError("accepted missing attachment") } catch {}
    assert(fm.fileExists(atPath: missing.appendingPathComponent("pending.json").path))
    try restored.acknowledge(missing.lastPathComponent)
    let invalid = try store.begin()
    try inbox.publish(batch: invalid, attachments: [["path": source.path, "type": 3]], text: [])
    store.finish(invalid, keep: true)
    do { _ = try restored.next(); fatalError("accepted path outside batch") } catch {}
    assert(fm.fileExists(atPath: source.path))
    print("PASS: delayed publication, Unicode/space/percent paths, immutable same-name shares, isolated cancellation, restart and ack retention")
  }
}

import Foundation

@main struct GrantStoreTests {
  static func main() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let one = base.appendingPathComponent("one"), two = base.appendingPathComponent("two")
    try fm.createDirectory(at: one, withIntermediateDirectories: true)
    try fm.createDirectory(at: two, withIntermediateDirectories: true)
    var starts = 0, stops = 0, allowed = true
    let storage = base.appendingPathComponent("grants")
    let store = IosWorkspaceGrantStore(root: storage, start: { _ in starts += 1; return allowed }, stop: { _ in stops += 1 })
    func expectFailure(_ work: () throws -> Void) { do { try work(); fatalError("Expected failure") } catch {} }
    let a = try store.save(one)["grantId"]!, b = try store.save(two)["grantId"]!
    assert(starts == stops)
    try store.prune([]) // Pending picker results are not discarded before save.
    let probed = try store.probe(a); assert(probed == one.resolvingSymlinksInPath().path)
    try store.adopt(a); try store.adopt(b)
    let lease = try store.acquire([a])["leaseId"] as! String
    assert(starts == stops + 1)
    let extended = try store.acquire([b], retaining: lease)
    assert(extended["leaseId"] as? String == lease && starts == stops + 2)
    try store.prune([]) // Live roots survive catalog deletion until acknowledged.
    expectFailure { try store.discard(a) }
    expectFailure { _ = try store.acquire(["../../escape"], retaining: lease) }
    assert(starts == stops + 2) // Failed extension leaves live union intact.
    _ = try store.retainOnly(lease, ids: [b]); assert(starts == stops + 1)
    try store.prune([b]); expectFailure { _ = try store.probe(a) }
    store.release(lease); store.release(lease); assert(starts == stops)
    allowed = false; expectFailure { _ = try store.probe(b) }; allowed = true
    // Reconstruct from actual persisted bookmark bytes, not an in-memory URL.
    let reopened = IosWorkspaceGrantStore(root: storage, start: { _ in true }, stop: { _ in })
    let restored = try reopened.probe(b); assert(restored == two.resolvingSymlinksInPath().path)
    try fm.removeItem(at: two); expectFailure { _ = try reopened.probe(b) }
    expectFailure { _ = try store.save(URL(string: "https://example.invalid/folder")!) }
    print("PASS: persistent bookmark, balanced probe, union lease, rollback, pending/active cleanup, restart, revocation and missing source")
  }
}

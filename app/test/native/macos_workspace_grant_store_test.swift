import Foundation

@main struct MacosWorkspaceGrantTests {
  static func main() throws {
    let args = CommandLine.arguments
    if args.count == 5 && args[1] == "--reopen" {
      let store = IosWorkspaceGrantStore(root: URL(fileURLWithPath: args[2]), start: { _ in true }, stop: { _ in })
      let path = try store.probe(args[3])
      guard path == args[4] else { fatalError("Persisted grant moved") }
      print("PASS: fresh-process macOS bookmark resolution (scope authority injected)")
      return
    }
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let one = base.appendingPathComponent("one"), two = base.appendingPathComponent("two")
    try fm.createDirectory(at: one, withIntermediateDirectories: true)
    try fm.createDirectory(at: two, withIntermediateDirectories: true)
    let content = one.appendingPathComponent("user-content.txt")
    try Data("Keep original content".utf8).write(to: content)
    let storage = base.appendingPathComponent("private-grants")
    var starts = 0, stops = 0, denied = false, checks = 0
    func check(_ value: Bool) { checks += 1; precondition(value) }
    func fails(_ work: () throws -> Void) {
      do { try work(); fatalError("Expected failure") } catch { checks += 1 }
    }
    let store = IosWorkspaceGrantStore(root: storage, start: { _ in
      if denied { return false }; starts += 1; return true
    }, stop: { _ in stops += 1 })
    let a = try store.save(one)["grantId"]!, b = try store.save(two)["grantId"]!
    check(starts == stops)
    try store.prune([]) // Unadopted picker results remain protected.
    check(fm.fileExists(atPath: storage.appendingPathComponent(a + ".bookmark").path))
    try store.adopt(a); try store.adopt(b)
    let first = try store.acquire([a])["leaseId"] as! String
    let second = try store.acquire([a])["leaseId"] as! String
    check(starts == stops + 1) // One security scope, two lease references.
    store.release(first); check(starts == stops + 1)
    fails { try store.discard(a) }
    fails { _ = try store.acquire([b, UUID().uuidString.lowercased()], retaining: second) }
    check(starts == stops + 1) // Newly acquired b rolled back; a still serves.
    try store.prune([])
    check(fm.fileExists(atPath: storage.appendingPathComponent(a + ".bookmark").path))
    store.release(second); store.release(second); check(starts == stops)
    denied = true
    fails { _ = try store.probe(a) }
    check(fm.fileExists(atPath: storage.appendingPathComponent(a + ".bookmark").path))
    denied = false
    let fresh = Process()
    fresh.executableURL = URL(fileURLWithPath: args[0])
    fresh.arguments = ["--reopen", storage.path, a, one.resolvingSymlinksInPath().path]
    try fresh.run(); fresh.waitUntilExit(); check(fresh.terminationStatus == 0)
    fails { _ = try store.probe(one.path) } // Legacy locator is never a grant ID.
    let alias = UUID().uuidString.lowercased()
    let aliasFile = storage.appendingPathComponent(alias + ".bookmark")
    try fm.createSymbolicLink(at: aliasFile, withDestinationURL: storage.appendingPathComponent(a + ".bookmark"))
    fails { _ = try store.probe(alias) }
    fails { try store.discard(alias) }
    check((try? aliasFile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
    try fm.removeItem(at: aliasFile)
    try store.prune([])
    check(!fm.fileExists(atPath: storage.appendingPathComponent(a + ".bookmark").path))
    check(fm.fileExists(atPath: content.path))
    check(starts == stops)
    print("PASS: \(checks) macOS grant assertions; real bookmark bytes, fresh process, reference counts, rollback, revoked access, private-only cleanup; no sandbox/device claim")
  }
}

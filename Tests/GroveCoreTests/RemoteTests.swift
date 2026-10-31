import Foundation
import Testing

@testable import GroveCore

@Suite struct RemoteTests {
    let base: URL
    let bare: URL
    let a: URL
    let b: URL
    let git = Git()

    init() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("grove-remote-\(UUID().uuidString)")
        bare = base.appendingPathComponent("origin.git")
        a = base.appendingPathComponent("a")
        b = base.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        _ = try await git.run(["init", "-q", "--bare", "-b", "main", bare.path], in: base)
        for d in [a, b] {
            _ = try await git.run(["clone", "-q", bare.path, d.path], in: base)
            for kv in [("user.name", "T"), ("user.email", "t@x"), ("commit.gpgsign", "false")] {
                _ = try await git.run(["config", kv.0, kv.1], in: d)
            }
        }
    }

    private func commit(_ d: URL, _ file: String, _ msg: String) async throws {
        try msg.write(to: d.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: d)
        _ = try await git.run(["commit", "-qm", msg], in: d)
    }

    @Test func pushPublishesAndPullFastForwards() async throws {
        try await commit(a, "f", "one")
        let ra = try await Repository.open(a)
        try await ra.push { _ in }  // no upstream yet → -u origin main
        let main = try #require(try await ra.refs().first { $0.name == "main" && $0.kind == .branch })
        #expect(main.upstream == "origin/main")

        let rb = try await Repository.open(b)
        try await rb.fetch { _ in }
        #expect(try await rb.refs().contains { $0.name == "origin/main" })
        _ = try await git.run(["switch", "-q", "main"], in: b)  // tracking branch from the fetched remote
        try await commit(a, "g", "two")
        try await ra.push { _ in }
        try await rb.pull(.fastForwardOnly) { _ in }
        #expect(try await rb.message(of: "HEAD").hasPrefix("two"))

        // Diverged: ff-only refuses, rebase succeeds.
        try await commit(a, "h", "three")
        try await ra.push { _ in }
        try await commit(b, "i", "local")
        await #expect(throws: GitError.self) { try await rb.pull(.fastForwardOnly) { _ in } }
        try await rb.pull(.rebase) { _ in }
        #expect(try await rb.message(of: "HEAD").hasPrefix("local"))
        #expect(try await rb.message(of: "HEAD~1").hasPrefix("three"))

        // Rejected non-ff push, then force-with-lease after the remote moved on.
        try await rb.push { _ in }
        try await commit(a, "j", "a-diverges")
        await #expect(throws: GitError.self) { try await ra.push { _ in } }
        try await ra.fetch { _ in }
        try await ra.push(force: true) { _ in }
    }

    @Test func progressAndObserver() async throws {
        let events = Box()
        let observed = Git(observer: { events.add($0) })
        try await commit(a, "f", "one")
        let ra = try await Repository.open(a, git: observed)
        let lines = Box()
        try await ra.push { lines.addLine($0) }
        let finished = events.events.filter { if case .finished = $0.phase { true } else { false } }
        #expect(finished.contains { $0.arguments.first == "push" && !$0.isReadOnly })
        #expect(finished.contains { $0.arguments.first == "rev-parse" && $0.isReadOnly })
        #expect(lines.lines.contains { $0.contains("main") })  // "* [new branch] main -> main"
    }

    @Test func cancellationTerminatesGit() async throws {
        let start = Date()
        let task = Task {
            try await git.runWithProgress(["-c", "alias.nap=!sleep 10", "nap"], in: a) { _ in }
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func readOnlyClassification() {
        func ro(_ a: String...) -> Bool { GitEvent(id: UUID(), arguments: a, phase: .started).isReadOnly }
        #expect(ro("status", "-z") && ro("remote") && ro("stash", "list") && ro("-c", "x=y", "log") && ro("config", "--get", "user.name"))
        #expect(!ro("remote", "add", "o", "u") && !ro("stash", "push") && !ro("branch", "-d", "x") && !ro("push") && !ro("commit"))
        #expect(ro("config", "user.name") && ro("config", "--list"))
        #expect(!ro("config", "user.name", "T") && !ro("config", "--global", "user.name", "T"))
    }

    @Test func collapseProgress() {
        #expect(Git.collapseProgress("Counting: 1%\rCounting: 50%\rCounting: 100%, done.\nok") == "Counting: 100%, done.\nok")
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [GitEvent] = []
    private var _lines: [String] = []
    func add(_ e: GitEvent) { lock.withLock { _events.append(e) } }
    func addLine(_ l: String) { lock.withLock { _lines.append(l) } }
    var events: [GitEvent] { lock.withLock { _events } }
    var lines: [String] { lock.withLock { _lines } }
}

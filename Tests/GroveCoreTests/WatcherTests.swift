import Foundation
import Testing

@testable import GroveCore

@Suite struct WatcherTests {
    @Test func classify() {
        let root = "/r", git = ["/r/.git"]
        func c(_ p: String) -> RepositoryWatcher.Change { RepositoryWatcher.classify(path: p, root: root, gitDirs: git) }
        #expect(c("/r/src/a.swift") == .workingTree)
        #expect(c("/r/.git/index") == .index)
        #expect(c("/r/.git/index.lock") == [])
        #expect(c("/r/.git/refs/heads/main.lock") == [])
        #expect(c("/r/.git/HEAD").contains(.refs))
        #expect(c("/r/.git/refs/remotes/origin/main").contains(.refs))
        #expect(c("/r/.git/packed-refs").contains(.refs))
        #expect(c("/r/.git/objects/ab/cdef") == [])
        #expect(c("/r/.git/logs/HEAD") == [])
        #expect(c("/r/vendor/sub/.git/index") == [])
        #expect(c("/elsewhere/x") == [])
        // Linked worktree: refs live in the common dir outside the tree.
        #expect(RepositoryWatcher.classify(path: "/main/.git/refs/heads/x", root: "/wt",
                                           gitDirs: ["/main/.git/worktrees/wt", "/main/.git"]).contains(.refs))
    }

    @Test func firesOnFileAndRefChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = Git()
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
        let repo = try await Repository.open(dir)
        let seen = Seen()
        let watcher = repo.watch { seen.add($0) }
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        try "x".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(await seen.wait(for: .workingTree))

        _ = try await git.run(["add", "a.txt"], in: dir)
        _ = try await git.run(["commit", "-qm", "c"], in: dir)
        #expect(await seen.wait(for: .refs))
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var all: RepositoryWatcher.Change = []

    func add(_ c: RepositoryWatcher.Change) { lock.withLock { all.formUnion(c) } }

    func wait(for c: RepositoryWatcher.Change) async -> Bool {
        for _ in 0..<50 {
            if lock.withLock({ all.contains(c) }) {
                lock.withLock { all = [] }
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

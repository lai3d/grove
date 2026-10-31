import Foundation
import Testing

@testable import GroveCore

@Suite struct WorktreeTests {
    let base: URL
    let dir: URL
    let git = Git()

    init() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("grove-wt-\(UUID().uuidString)")
        dir = base.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
        try "x\n".write(to: dir.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: dir)
        _ = try await git.run(["commit", "-qm", "one"], in: dir)
    }

    @Test func parseWorktreeList() {
        let text = "worktree /r\nHEAD aaa\nbranch refs/heads/main\n\nworktree /r-wt\nHEAD bbb\ndetached\nlocked reason\n\n"
        let w = GitParse.worktrees(text)
        #expect(w.map(\.path) == ["/r", "/r-wt"] && w[0].isMain && w[0].branch == "main")
        #expect(w[1].branch == nil && w[1].isLocked && !w[1].isMain)
    }

    @Test func parseSubmoduleStatus() {
        let s = GitParse.submodules(" 1234 libs/a (v1.0)\n-5678 libs/b\n+9abc libs/c (heads/main)\n")
        #expect(s.map(\.path) == ["libs/a", "libs/b", "libs/c"])
        #expect(s.map(\.state) == [.upToDate, .notInitialized, .differentCommit])
        #expect(s[0].describe == "v1.0" && s[1].describe == nil)
    }

    @Test func addListRemoveWorktree() async throws {
        let repo = try await Repository.open(dir)
        let path = base.appendingPathComponent("feature-wt").path
        try await repo.addWorktree(at: path, branch: "feature", createFrom: "HEAD")
        var list = try await repo.worktrees()
        #expect(list.count == 2 && list[1].branch == "feature" && list[1].path.hasSuffix("feature-wt"))
        let other = try await Repository.open(URL(fileURLWithPath: path))
        #expect(await other.currentBranch() == "feature")

        try "dirty".write(to: URL(fileURLWithPath: path).appendingPathComponent("f"), atomically: true, encoding: .utf8)
        await #expect(throws: GitError.self) { try await repo.removeWorktree(at: path, force: false) }
        try await repo.removeWorktree(at: path, force: true)
        list = try await repo.worktrees()
        #expect(list.count == 1)
    }

    @Test func submoduleLifecycle() async throws {
        let lib = base.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"]] {
            _ = try await git.run(args, in: lib)
        }
        try "lib\n".write(to: lib.appendingPathComponent("l"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: lib)
        _ = try await git.run(["-c", "commit.gpgsign=false", "commit", "-qm", "lib"], in: lib)

        let repo = try await Repository.open(dir)
        #expect(try await repo.submodules().isEmpty)
        _ = try await git.run(["-c", "protocol.file.allow=always", "submodule", "add", "-q", lib.path, "vendor/lib"], in: dir)
        _ = try await git.run(["commit", "-qm", "add submodule"], in: dir)
        var subs = try await repo.submodules()
        #expect(subs.map(\.path) == ["vendor/lib"] && subs[0].state == .upToDate)

        // Fresh clone: submodule not initialized until updated.
        let clone = base.appendingPathComponent("clone")
        _ = try await git.run(["clone", "-q", dir.path, clone.path], in: base)
        let cloned = try await Repository.open(clone)
        subs = try await cloned.submodules()
        #expect(subs.first?.state == .notInitialized)
        var g = Git()
        g.environment["GIT_CONFIG_COUNT"] = "1"
        g.environment["GIT_CONFIG_KEY_0"] = "protocol.file.allow"
        g.environment["GIT_CONFIG_VALUE_0"] = "always"
        let clonedWithFile = try await Repository.open(clone, git: g)
        try await clonedWithFile.updateSubmodule("vendor/lib")
        #expect(try await cloned.submodules().first?.state == .upToDate)
    }
}

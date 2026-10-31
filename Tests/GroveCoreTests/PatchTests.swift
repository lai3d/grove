import Foundation
import Testing

@testable import GroveCore

@Suite struct PatchTests {
    func makeRepo(_ name: String) async throws -> (URL, Git, Repository) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-patch-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = Git()
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
        return (dir, git, try await Repository.open(dir))
    }

    func commit(_ git: Git, _ dir: URL, _ file: String, _ text: String, _ msg: String) async throws -> Commit {
        try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: dir)
        _ = try await git.run(["commit", "-qm", msg], in: dir)
        let out = try await git.runString(["log", "-1", "-z", GitParse.logFormat], in: dir)
        return try #require(GitParse.commit(Data(out.utf8)))
    }

    @Test func exportAndApplyMailbox() async throws {
        let (src, git, repo) = try await makeRepo("src")
        _ = try await commit(git, src, "f", "base\n", "base")
        let a = try await commit(git, src, "f", "base\none\n", "one")
        let b = try await commit(git, src, "g", "g\n", "two")
        let mbox = try await repo.formatPatches([b, a])  // any order in, oldest first out
        #expect(Repository.patchKind(mbox) == .mailbox)
        #expect(mbox.components(separatedBy: "\nFrom ").count == 2)
        #expect(mbox.contains("[PATCH 1/2] one") && mbox.contains("[PATCH 2/2] two"))
        let single = try await repo.formatPatches([a])
        #expect(single.contains("Subject: [PATCH] one"))

        let (dst, git2, repo2) = try await makeRepo("dst")
        _ = try await commit(git2, dst, "f", "base\n", "base")
        let file = dst.deletingLastPathComponent().appendingPathComponent("p-\(UUID()).mbox")
        try mbox.write(to: file, atomically: true, encoding: .utf8)
        try await repo2.applyPatch(file)
        #expect(try await git2.runString(["log", "--format=%s"], in: dst) == "two\none\nbase\n")
        #expect(repo2.operation() == nil)

        // A patch that doesn't apply pauses `am`, seen as an operation that can be aborted.
        let (other, git3, repo3) = try await makeRepo("other")
        _ = try await commit(git3, other, "f", "different\n", "base")
        await #expect(throws: GitError.self) { try await repo3.applyPatch(file) }
        #expect(repo3.operation() == .applyMailbox)
        try await repo3.abortOperation(.applyMailbox)
        #expect(repo3.operation() == nil)
    }

    @Test func applyPlainDiff() async throws {
        let (dir, git, repo) = try await makeRepo("diff")
        _ = try await commit(git, dir, "f", "1\n2\n3\n", "base")
        try "1\nTWO\n3\n".write(to: dir.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        let diff = try await git.runString(["diff"], in: dir)
        #expect(Repository.patchKind(diff) == .diff)
        _ = try await git.run(["checkout", "--", "f"], in: dir)
        let file = dir.deletingLastPathComponent().appendingPathComponent("d-\(UUID()).diff")
        try diff.write(to: file, atomically: true, encoding: .utf8)
        try await repo.applyPatch(file)
        #expect(try String(contentsOf: dir.appendingPathComponent("f"), encoding: .utf8) == "1\nTWO\n3\n")
    }
}

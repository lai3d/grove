import Foundation
import Testing

@testable import GroveCore

@Suite struct MultiCommitTests {
    func makeRepo() async throws -> (URL, Git, Repository) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-multi-\(UUID().uuidString)")
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

    func subjects(_ git: Git, _ dir: URL) async throws -> [String] {
        try await git.runString(["log", "--format=%s"], in: dir).split(separator: "\n").map(String.init)
    }

    @Test func squashPlan() {
        func step(_ id: String) -> RebaseStep {
            RebaseStep(commit: Commit(id: id, parents: [], authorName: "", authorEmail: "", date: .now, subject: id),
                       originalMessage: "msg \(id)\n")
        }
        let c = ["a", "b", "c", "d"].map(step)
        let plan = try! #require(RebaseStep.squashing(c, ids: ["a", "b", "c"]))
        #expect(plan.map(\.action) == [.pick, .squash, .squash, .pick])
        #expect(plan[0].message == "msg a\n\nmsg b\n\nmsg c")
        #expect(RebaseStep.squashing(c, ids: ["a", "c"]) == nil)  // gap
        #expect(RebaseStep.squashing(c, ids: ["b", "c"]) == nil)  // doesn't start the range
        #expect(RebaseStep.squashing(c, ids: ["a"]) == nil)
    }

    @Test func squashConsecutiveCommits() async throws {
        let (dir, git, repo) = try await makeRepo()
        _ = try await commit(git, dir, "f", "0", "base")
        let a = try await commit(git, dir, "a", "a", "add a")
        let b = try await commit(git, dir, "b", "b", "add b")
        let c = try await commit(git, dir, "c", "c", "add c")
        _ = try await commit(git, dir, "d", "d", "add d")
        try await repo.squash([c, a, b])  // order doesn't matter
        #expect(try await subjects(git, dir) == ["add d", "add a", "base"])
        let body = try await git.runString(["log", "-1", "--skip=1", "--format=%B"], in: dir)
        #expect(body.contains("add b") && body.contains("add c"))
        for f in ["a", "b", "c", "d"] { #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path)) }

        let (dir2, git2, repo2) = try await makeRepo()
        let r = try await commit(git2, dir2, "f", "0", "root")
        let x = try await commit(git2, dir2, "x", "x", "x")
        _ = try await commit(git2, dir2, "y", "y", "y")
        let z = try await commit(git2, dir2, "z", "z", "z")
        await #expect(throws: Repository.SquashError.self) { try await repo2.squash([x, z]) }  // gap
        await #expect(throws: Repository.SquashError.self) { try await repo2.squash([r, x]) }  // root commit
        await #expect(throws: Repository.SquashError.self) { try await repo2.squash([x]) }
    }

    @Test func cherryPickAndRevertSeveral() async throws {
        let (dir, git, repo) = try await makeRepo()
        _ = try await commit(git, dir, "f", "0", "base")
        _ = try await git.run(["switch", "-qc", "side"], in: dir)
        let one = try await commit(git, dir, "one", "1", "one")
        _ = try await commit(git, dir, "skip", "s", "not this")
        let three = try await commit(git, dir, "three", "3", "three")
        _ = try await git.run(["switch", "-q", "main"], in: dir)

        try await repo.cherryPick([one, three])
        #expect(try await subjects(git, dir) == ["three", "one", "base"])
        let picked = try await git.runString(["log", "-2", "-z", GitParse.logFormat], in: dir)
            .split(separator: "\0").compactMap { GitParse.commit(Data($0.utf8)) }
        try await repo.revert(picked)  // newest first
        #expect(try await subjects(git, dir) == ["Revert \"one\"", "Revert \"three\"", "three", "one", "base"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("one").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("three").path))
    }
}

import Foundation
import Testing

@testable import GroveCore

@Suite struct MergeTests {
    let dir: URL
    let git = Git()

    init() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
        try await commit("f.txt", "base\n", "base")
        _ = try await git.run(["switch", "-qc", "feature"], in: dir)
        try await commit("f.txt", "feature\n", "feature change")
        try await commit("g.txt", "g\n", "feature extra")
        _ = try await git.run(["switch", "-q", "main"], in: dir)
        try await commit("f.txt", "main\n", "main change")
    }

    private func commit(_ file: String, _ content: String, _ msg: String) async throws {
        try content.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: dir)
        _ = try await git.run(["commit", "-qm", msg], in: dir)
    }

    private func read(_ f: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) }

    @Test func mergeConflictResolveTheirsAndContinue() async throws {
        let repo = try await Repository.open(dir)
        #expect(repo.operation() == nil)
        await #expect(throws: GitError.self) { try await repo.merge("feature") }
        #expect(repo.operation() == .merge(from: "feature"))
        let conflicted = try await repo.status().filter { $0.kind == .unmerged }
        #expect(conflicted.map(\.path) == ["f.txt"])

        try await repo.resolve("f.txt", taking: .theirs)
        #expect(try read("f.txt") == "feature\n")
        #expect(try await repo.status().contains { $0.kind == .unmerged } == false)
        try await repo.continueOperation(.merge(from: "feature"))
        #expect(repo.operation() == nil)
        let parents = try await git.runString(["log", "-1", "--format=%P"], in: dir).split(separator: " ")
        #expect(parents.count == 2)
    }

    @Test func rebaseConflictAbortRestores() async throws {
        let repo = try await Repository.open(dir)
        let before = try await repo.headID()
        await #expect(throws: GitError.self) { try await repo.rebase(onto: "feature") }
        guard case .rebase(let branch, _, let step, let total)? = repo.operation() else {
            Issue.record("expected rebase state, got \(String(describing: repo.operation()))")
            return
        }
        #expect(branch == "main" && step == 1 && total == 1)
        try await repo.abortOperation(repo.operation()!)
        #expect(repo.operation() == nil)
        #expect(await repo.headID() == before)
    }

    @Test func rebaseResolveOursMarkResolvedContinue() async throws {
        let repo = try await Repository.open(dir)
        await #expect(throws: GitError.self) { try await repo.rebase(onto: "feature") }
        try "merged by hand\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try await repo.markResolved("f.txt")
        try await repo.continueOperation(repo.operation()!)
        #expect(repo.operation() == nil)
        let log = try await git.runString(["log", "--format=%s"], in: dir)
        #expect(log.hasPrefix("main change\nfeature extra\nfeature change\nbase"))
        #expect(try read("f.txt") == "merged by hand\n")
    }

    @Test func cleanMergeAndCherryPickSkip() async throws {
        let repo = try await Repository.open(dir)
        // Conflicting cherry-pick → skip leaves history unchanged.
        let featureTip = try await git.runString(["rev-parse", "feature~1"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try? await git.run(["cherry-pick", featureTip], in: dir)
        #expect(repo.operation() == .cherryPick)
        try await repo.skipOperation(.cherryPick)
        #expect(repo.operation() == nil)

        // A no-conflict merge with --no-ff.
        _ = try await git.run(["switch", "-qc", "other", "main"], in: dir)
        try await commit("h.txt", "h\n", "other")
        _ = try await git.run(["switch", "-q", "main"], in: dir)
        try await repo.merge("other", noFastForward: true)
        #expect(try await git.runString(["log", "-1", "--format=%s"], in: dir).hasPrefix("Merge branch 'other'"))
    }
}

import Foundation
import Testing

@testable import GroveCore

@Suite struct BisectTests {
    @Test func parsers() {
        #expect(BisectState.culprit(fromLog: "git bisect start\n# bad: [abc] x\n# first bad commit: [d34db33f] Break it\n") == "d34db33f")
        #expect(BisectState.culprit(fromLog: "git bisect start\n") == nil)
        let v = BisectState.vars("bisect_rev='abc'\nbisect_nr=6\nbisect_good=2\nbisect_bad=3\nbisect_all=13\nbisect_steps=3\n")
        #expect(v.remaining == 6 && v.steps == 3)
    }

    /// 16 commits; commit 11 introduces the bug. Bisect from the tip (bad) and the root (good).
    @Test func findsFirstBadCommit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-bisect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = Git()
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
        var ids: [String] = []
        for n in 0..<16 {
            try "\(n)\n\(n >= 11 ? "broken" : "ok")\n".write(to: dir.appendingPathComponent("f"), atomically: true, encoding: .utf8)
            _ = try await git.run(["add", "."], in: dir)
            _ = try await git.run(["commit", "-qm", "c\(n)"], in: dir)
            ids.append(try await git.runString(["rev-parse", "HEAD"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let repo = try await Repository.open(dir)
        #expect(await repo.bisectState() == nil)

        try await repo.bisectStart()
        #expect(await repo.bisectState()?.phase == .needsBad)
        try await repo.bisect(.bad)
        #expect(await repo.bisectState()?.phase == .needsGood)
        try await repo.bisect(.good, ids[0])
        let first = try #require(await repo.bisectState())
        #expect(first.phase == .testing && first.remaining != nil && first.steps == 3)
        #expect(first.mark(of: ids[15]) == .bad && first.mark(of: ids[0]) == .good)

        var rounds = 0
        while let s = await repo.bisectState(), s.phase == .testing, rounds < 10 {
            let text = try String(contentsOf: dir.appendingPathComponent("f"), encoding: .utf8)
            if text.hasPrefix("13\n") { try await repo.bisect(.skip); rounds += 1; continue }  // untestable commit
            try await repo.bisect(text.contains("broken") ? .bad : .good)
            rounds += 1
        }
        let done = try #require(await repo.bisectState())
        #expect(done.phase == .found && done.culprit == ids[11])

        try await repo.bisectReset()
        #expect(await repo.bisectState() == nil)
        let head = await repo.headID(), branch = await repo.currentBranch()
        #expect(head == ids[15] && branch == "main")
    }
}

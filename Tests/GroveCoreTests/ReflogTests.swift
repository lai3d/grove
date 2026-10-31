import Foundation
import Testing

@testable import GroveCore

@Suite struct ReflogTests {
    @Test func reflogRecordsActionsAndFindsLostCommits() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-reflog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = Git()
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
        let repo = try await Repository.open(dir)
        #expect(try await repo.reflog().isEmpty)  // unborn branch

        for n in ["one", "two"] {
            try n.write(to: dir.appendingPathComponent("f"), atomically: true, encoding: .utf8)
            _ = try await git.run(["add", "."], in: dir)
            _ = try await git.run(["commit", "-qm", n], in: dir)
        }
        let lost = try #require(await repo.headID())
        try await repo.reset(.hard, to: "HEAD~1")
        _ = try await git.run(["switch", "-qc", "side"], in: dir)

        let log = try await repo.reflog()
        #expect(log.map(\.action) == ["checkout", "reset", "commit", "commit (initial)"])
        #expect(log[0].message == "moving from main to side")
        #expect(log[2].commitID == lost && log[2].message == "two")
        #expect(log[1].selector == "HEAD@{1}")
        #expect(abs(log[0].date.timeIntervalSinceNow) < 120)

        // The reset-away commit is still reachable from the reflog.
        let c = try #require(try await repo.commit(log[2].commitID))
        #expect(c.subject == "two" && c.id == lost)
    }
}

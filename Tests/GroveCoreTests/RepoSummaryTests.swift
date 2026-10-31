import Foundation
import Testing

@testable import GroveCore

@Suite struct RepoSummaryTests {
    @Test func parsesBranchAndCounts() {
        let raw = ["# branch.oid 0123456789abcdef", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -5",
                   "1 .M N... 100644 100644 100644 a a f.txt", "2 R. N... 100644 100644 100644 a a R100 new", "1 old",
                   "u UU N... 100644 100644 100644 100644 a b c c.txt", "? x"].joined(separator: "\0") + "\0"
        let s = RepoSummary(porcelain: Data(raw.utf8))
        #expect(s.branch == "main" && s.detachedAt == nil && s.upstream == "origin/main")
        #expect(s.ahead == 2 && s.behind == 5 && s.changed == 4 && s.conflicts == 1)

        let detached = RepoSummary(porcelain: Data("# branch.oid abcdef0123\0# branch.head (detached)\0".utf8))
        #expect(detached.branch == nil && detached.detachedAt == "abcdef01" && detached.changed == 0)
    }

    @Test func loadsRealRepository() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = Git()
        for args in [["init", "-q", "-b", "trunk"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"], ["commit", "-q", "--allow-empty", "-m", "x"]] {
            _ = try await git.run(args, in: dir)
        }
        try "a".write(to: dir.appendingPathComponent("a"), atomically: true, encoding: .utf8)
        let s = try #require(await RepoSummary.load(dir))
        #expect(s.branch == "trunk" && s.changed == 1 && s.upstream == nil && s.ahead == 0)
        #expect(await RepoSummary.load(FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID())")) == nil)
    }
}

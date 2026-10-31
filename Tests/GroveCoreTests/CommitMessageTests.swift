import Foundation
import Testing

@testable import GroveCore

@Suite struct CommitMessageTests {
    @Test func templateSplitsGuidance() {
        let t = CommitTemplate("# Subject: imperative, ≤ 50 chars\n## Why?\n\nTicket: \n\n# Co-authors go last\n")
        #expect(t.text == "Ticket:")
        #expect(t.hint == "Subject: imperative, ≤ 50 chars\nWhy?\nCo-authors go last")
        #expect(CommitTemplate("feat: \r\n").text == "feat:")
    }

    @Test func templateAndRecentMessages() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-msg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = Git()
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
        let repo = try await Repository.open(dir)
        #expect(await repo.commitTemplate() == nil)
        #expect(await repo.recentMessages().isEmpty)  // unborn HEAD

        try "# What changed?\nJIRA-\n".write(to: dir.appendingPathComponent(".gitmessage"), atomically: true, encoding: .utf8)
        _ = try await git.run(["config", "commit.template", ".gitmessage"], in: dir)
        let t = try #require(await repo.commitTemplate())
        #expect(t.text == "JIRA-" && t.hint == "What changed?")

        for m in ["one\n\nbody", "two", "one\n\nbody", "three"] {
            _ = try await git.run(["commit", "-q", "--allow-empty", "-m", m], in: dir)
        }
        #expect(await repo.recentMessages() == ["three", "one\n\nbody", "two"])
        #expect(await repo.recentMessages(limit: 1) == ["three"])
    }
}

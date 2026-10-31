import Foundation
import Testing

@testable import GroveCore

@Suite struct InteractiveRebaseTests {
    let dir: URL
    let git = Git()

    init() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-irebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
        for (i, name) in ["base", "a", "b", "c", "d"].enumerated() {
            try "\(i)\n".write(to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            _ = try await git.run(["add", "."], in: dir)
            _ = try await git.run(["commit", "-qm", "add \(name)\n\nbody of \(name)"], in: dir)
        }
    }

    private func subjects() async throws -> [String] {
        try await git.runString(["log", "--format=%s"], in: dir).split(separator: "\n").map(String.init)
    }

    private func steps(_ repo: Repository) async throws -> [RebaseStep] {
        try await repo.rebaseCandidates(after: "HEAD~4")
    }

    @Test func candidatesOldestFirst() async throws {
        let repo = try await Repository.open(dir)
        let s = try await steps(repo)
        #expect(s.map(\.commit.subject) == ["add a", "add b", "add c", "add d"])
        #expect(s[0].originalMessage.contains("body of a"))
    }

    @Test func reorderDropRewordFixupSquash() async throws {
        let repo = try await Repository.open(dir)
        var s = try await steps(repo)  // a b c d
        s[0].action = .reword
        s[0].message = "A, reworded"
        s[1].action = .drop             // b
        s[3].action = .fixup            // d into c
        let plan = [s[0], s[2], s[3], s[1]]  // a c d(b dropped, moved to end)
        try await repo.interactiveRebase(onto: "HEAD~4", steps: plan)
        #expect(repo.operation() == nil)
        #expect(try await subjects() == ["add c", "A, reworded", "add base"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("d.txt").path))
        #expect(try await repo.message(of: "HEAD").hasPrefix("add c\n\nbody of c"))  // fixup keeps c's message
    }

    @Test func squashCombinesMessages() async throws {
        let repo = try await Repository.open(dir)
        var s = try await steps(repo)
        s[1].action = .squash  // b into a
        s[2].action = .squash  // c into a
        #expect(Repository.squashMessage(Array(s[0...2])).hasPrefix("add a\n\nbody of a\n\nadd b"))
        try await repo.interactiveRebase(onto: "HEAD~4", steps: s)
        #expect(try await subjects() == ["add d", "add a", "add base"])
        let msg = try await repo.message(of: "HEAD~1")
        #expect(msg.contains("body of a") && msg.contains("add b") && msg.contains("add c"))
    }

    @Test func squashWithCustomMessageAndInvalidPlans() async throws {
        let repo = try await Repository.open(dir)
        var s = try await steps(repo)
        s[2].action = .squash
        s[1].message = "b+c together"
        try await repo.interactiveRebase(onto: "HEAD~4", steps: s)
        #expect(try await subjects() == ["add d", "b+c together", "add a", "add base"])

        var bad = try await repo.rebaseCandidates(after: "HEAD~3")
        bad[0].action = .fixup
        await #expect(throws: GitError.self) { try await repo.interactiveRebase(onto: "HEAD~3", steps: bad) }
    }

    @Test func conflictPausesWithRebaseState() async throws {
        let repo = try await Repository.open(dir)
        // Make b and a later commit touch the same line, then reorder so the later one goes first.
        try "edited\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["commit", "-qam", "edit b"], in: dir)
        var s = try await repo.rebaseCandidates(after: "HEAD~5")  // a b c d edit-b
        s.swapAt(1, 4)  // "edit b" before "add b"
        await #expect(throws: GitError.self) { try await repo.interactiveRebase(onto: "HEAD~5", steps: s) }
        guard case .rebase? = repo.operation() else {
            Issue.record("expected paused rebase")
            return
        }
        try await repo.abortOperation(repo.operation()!)
        #expect(try await subjects().first == "edit b")
    }
}

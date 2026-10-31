import Foundation
import Testing

@testable import GroveCore

@Suite struct UndoPrimitiveTests {
    let dir: URL
    let git = Git()

    init() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
        try write("a.txt", "1\n")
        _ = try await git.run(["add", "."], in: dir)
        _ = try await git.run(["commit", "-qm", "one"], in: dir)
    }

    private func write(_ f: String, _ s: String) throws {
        try s.write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8)
    }

    private func read(_ f: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) }

    @Test func undoCommitKeepsChangesStaged() async throws {
        let repo = try await Repository.open(dir)
        let before = try #require(await repo.headID())
        try write("a.txt", "2\n")
        try await repo.stage(["a.txt"])
        try await repo.commit(message: "two")
        try await repo.moveHead(to: before, mode: .soft)
        #expect(await repo.headID() == before)
        #expect(try await repo.status().first?.isStaged == true)
    }

    @Test func undoDiscardRestoresTrackedAndUntracked() async throws {
        let repo = try await Repository.open(dir)
        try write("a.txt", "edited\n")
        try write("new.txt", "fresh\n")
        let changes = try await repo.status()
        let snapshot = try #require(try await repo.snapshotChanges())
        let untracked = try #require(repo.readFiles(changes.filter { $0.kind == .untracked }.map(\.path)))
        try await repo.discard(changes)
        #expect(try read("a.txt") == "1\n")
        #expect(try await repo.status().isEmpty)

        try await repo.restoreSnapshot(snapshot)
        try repo.writeFiles(untracked)
        #expect(try read("a.txt") == "edited\n" && (try read("new.txt")) == "fresh\n")
    }

    @Test func undoHardResetAndBranchDelete() async throws {
        let repo = try await Repository.open(dir)
        try write("a.txt", "2\n")
        _ = try await git.run(["commit", "-qam", "two"], in: dir)
        try write("a.txt", "uncommitted\n")
        let head = try #require(await repo.headID())
        let snap = try #require(try await repo.snapshotChanges())

        try await repo.reset(.hard, to: "HEAD~1")
        #expect(try read("a.txt") == "1\n")
        try await repo.moveHead(to: head, mode: .hard)
        try await repo.restoreSnapshot(snap)
        #expect(try read("a.txt") == "uncommitted\n")

        try await repo.createBranch("gone", at: head, checkout: false)
        try await repo.deleteBranch("gone", force: true)
        try await repo.restoreBranch("gone", at: head)
        #expect(try await repo.refs().contains { $0.name == "gone" })
    }

    @Test func undoStashDrop() async throws {
        let repo = try await Repository.open(dir)
        try write("a.txt", "stashed\n")
        try await repo.stash(message: "keep me", includeUntracked: false)
        let s = try #require(try await repo.stashes().first)
        try await repo.dropStash(s)
        try await repo.restoreStash(s.id, message: s.message)
        #expect(try await repo.stashes().first?.id == s.id)
    }

    @Test func keepModeRefusesToClobber() async throws {
        let repo = try await Repository.open(dir)
        let before = try #require(await repo.headID())
        try write("a.txt", "2\n")
        _ = try await git.run(["commit", "-qam", "two"], in: dir)
        try write("a.txt", "dirty\n")
        await #expect(throws: GitError.self) { try await repo.moveHead(to: before, mode: .keep) }
        #expect(try read("a.txt") == "dirty\n")
    }
}

import Foundation
import Testing

@testable import GroveCore

@Suite struct StashTests {
    let dir: URL
    let git = Git()

    init() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-stash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
        try write("a.txt", "1\n")
        _ = try await git.run(["add", "."], in: dir)
        _ = try await git.run(["commit", "-qm", "base"], in: dir)
    }

    private func write(_ name: String, _ s: String) throws {
        try s.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func discardTrackedAndUntracked() async throws {
        let repo = try await Repository.open(dir)
        try write("a.txt", "changed\n")
        try write("new.txt", "x\n")
        // Staged part survives a discard of the unstaged part.
        try write("b.txt", "staged\n")
        _ = try await git.run(["add", "b.txt"], in: dir)
        try write("b.txt", "staged then edited\n")
        let changes = try await repo.status().filter(\.isUnstaged)
        try await repo.discard(changes)
        #expect(try read("a.txt") == "1\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.txt").path))
        #expect(try read("b.txt") == "staged\n")
        #expect(try await repo.status().map(\.path) == ["b.txt"])
    }

    @Test func stashLifecycle() async throws {
        let repo = try await Repository.open(dir)
        try write("a.txt", "first stash\n")
        try write("u.txt", "untracked\n")
        try await repo.stash(message: "wip one", includeUntracked: true)
        #expect(try await repo.status().isEmpty)

        try write("a.txt", "second stash\n")
        try await repo.stash(message: "wip two", includeUntracked: false)

        var list = try await repo.stashes()
        #expect(list.map(\.name) == ["stash@{0}", "stash@{1}"])
        #expect(list[0].message.hasSuffix("wip two") && list[1].message.hasSuffix("wip one"))

        let one = list[1]
        let files = try await repo.stashFiles(one)
        #expect(Set(files.map(\.path)) == ["a.txt", "u.txt"])
        let diff = try await repo.stashDiff(one, file: files.first { $0.path == "u.txt" }!)
        #expect(diff.contains("+untracked"))

        // Dropping "wip two" shifts "wip one" to stash@{0}; it's still found by id.
        try await repo.dropStash(list[0])
        list = try await repo.stashes()
        #expect(list.count == 1 && list[0].id == one.id && list[0].name == "stash@{0}")

        try await repo.applyStash(one, pop: false)
        #expect(try read("a.txt") == "first stash\n" && (try read("u.txt")) == "untracked\n")
        #expect(try await repo.stashes().count == 1)
        _ = try await git.run(["checkout", "--", "a.txt"], in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("u.txt"))
        try await repo.applyStash(one, pop: true)
        #expect(try await repo.stashes().isEmpty)
        await #expect(throws: GitError.self) { try await repo.dropStash(one) }
    }
}

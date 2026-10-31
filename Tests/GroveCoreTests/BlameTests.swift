import Foundation
import Testing

@testable import GroveCore

@Suite struct RewriteParentsTests {
    @Test func skipsUnkeptCommitsAndMerges() {
        // m merges x and y; only a, x-side commit b and root r are kept.
        //   a -> m -> (x -> b -> r) , (y -> r)
        let topo: [(String, [String])] = [("a", ["m"]), ("m", ["x", "y"]), ("x", ["b"]), ("y", ["r"]), ("b", ["r"]), ("r", [])]
        let out = Repository.rewriteParents(topo, keeping: ["a", "b", "r"])
        #expect(out["a"] == ["b", "r"])
        #expect(out["b"] == ["r"])
        #expect(out["r"] == [])
    }
}

@Suite struct BlameTests {
    let dir: URL
    let git = Git()

    init() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-blame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Ada"], ["config", "user.email", "a@x"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
    }

    private func commit(_ file: String, _ content: String, _ msg: String, author: String = "Ada") async throws {
        try content.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "-A"], in: dir)
        _ = try await git.run(["-c", "user.name=\(author)", "commit", "-qm", msg], in: dir)
    }

    @Test func blameAcrossCommitsAndRename() async throws {
        try await commit("old.txt", "one\ntwo\nthree\n", "first")
        try await commit("old.txt", "one\nTWO\nthree\n", "second", author: "Bob")
        _ = try await git.run(["mv", "old.txt", "new.txt"], in: dir)
        try await commit("new.txt", "one\nTWO\nthree\nfour\n", "rename and add", author: "Cy")
        try "one\nTWO\nthree\nfour\nfive\n".write(to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let repo = try await Repository.open(dir)
        let lines = try await repo.blame("new.txt")
        #expect(lines.map(\.content) == ["one", "TWO", "three", "four", "five"])
        #expect(lines.map(\.lineNumber) == [1, 2, 3, 4, 5])
        #expect(lines.map(\.author) == ["Ada", "Bob", "Ada", "Cy", "Not Committed Yet"])
        #expect(lines[0].summary == "first" && lines[0].originalPath == "old.txt")
        #expect(lines[4].isUncommitted && !lines[0].isUncommitted)
        #expect(lines[0].commitID == lines[2].commitID)

        let atHead = try await repo.blame("new.txt", at: "HEAD")
        #expect(atHead.count == 4)

        // History of new.txt follows the rename back to "first", parents chained.
        let history = try await repo.fileHistory("new.txt", includeHEAD: true)
        #expect(history.map(\.subject) == ["rename and add", "second", "first"])
        #expect(history[0].parents == [history[1].id] && history[1].parents == [history[2].id] && history[2].parents.isEmpty)
    }
}

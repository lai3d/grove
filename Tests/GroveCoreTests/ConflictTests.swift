import Foundation
import Testing

@testable import GroveCore

@Suite struct ConflictTests {
    static let twoWay = """
    header
    <<<<<<< HEAD
    ours 1
    ours 2
    =======
    theirs 1
    >>>>>>> feature
    middle
    <<<<<<< HEAD
    a
    =======
    b
    >>>>>>> feature
    footer

    """

    @Test func parseAndResolve() throws {
        let f = try #require(ConflictFile(Self.twoWay))
        #expect(f.conflicts.count == 2)
        #expect(f.conflicts[0].ours == ["ours 1", "ours 2"] && f.conflicts[0].theirs == ["theirs 1"])
        #expect(f.conflicts[0].oursLabel == "HEAD" && f.conflicts[0].theirsLabel == "feature" && f.conflicts[0].base == nil)
        #expect(f.resolved([0: .theirs, 1: .oursThenTheirs]) == "header\ntheirs 1\nmiddle\na\nb\nfooter\n")
        #expect(f.resolved([0: .ours, 1: .theirsThenOurs]) == "header\nours 1\nours 2\nmiddle\nb\na\nfooter\n")
        // Unresolved conflicts are written back with markers (round trip).
        #expect(f.resolved([:]) == Self.twoWay)
    }

    @Test func diff3AndMalformed() throws {
        let f = try #require(ConflictFile("<<<<<<< ours\nx\n||||||| base\no\n=======\ny\n>>>>>>> theirs"))
        #expect(f.conflicts[0].base == ["o"])
        #expect(f.resolved([0: .base]) == "o")
        #expect(ConflictFile("no markers\n") == nil)
        #expect(ConflictFile("<<<<<<< HEAD\nunterminated\n") == nil)
    }

    @Test func resolveRealMergeConflict() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = Git()
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
        func commit(_ s: String, _ m: String) async throws {
            try s.write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            _ = try await git.run(["commit", "-qam", m], in: dir)
        }
        try "one\ntwo\nthree\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: dir)
        _ = try await git.run(["commit", "-qm", "base"], in: dir)
        _ = try await git.run(["switch", "-qc", "feature"], in: dir)
        try await commit("one\nTWO from feature\nthree\n", "feature")
        _ = try await git.run(["switch", "-q", "main"], in: dir)
        try await commit("one\nTWO from main\nthree\n", "main")
        let repo = try await Repository.open(dir)
        await #expect(throws: GitError.self) { try await repo.merge("feature") }

        let text = try String(contentsOf: dir.appendingPathComponent("f.txt"), encoding: .utf8)
        let file = try #require(ConflictFile(text))
        #expect(file.conflicts.count == 1)
        try await repo.saveResolution("f.txt", text: file.resolved([0: .oursThenTheirs]))
        #expect(try await repo.status().contains { $0.kind == .unmerged } == false)
        try await repo.continueOperation(.merge(from: "feature"))
        let merged = try String(contentsOf: dir.appendingPathComponent("f.txt"), encoding: .utf8)
        #expect(merged == "one\nTWO from main\nTWO from feature\nthree\n")
    }
}

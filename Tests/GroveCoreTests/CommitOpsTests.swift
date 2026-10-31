import Foundation
import Testing

@testable import GroveCore

@Suite struct CommitOpsTests {
    let dir: URL
    let git = Git()

    init() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"], ["config", "tag.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
        try await commit("a.txt", "a1", "one")
        try await commit("a.txt", "a2", "two")
    }

    private func commit(_ file: String, _ content: String, _ msg: String) async throws {
        try content.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: dir)
        _ = try await git.run(["commit", "-qm", msg], in: dir)
    }

    private func head(_ repo: Repository) async throws -> Commit {
        var it = repo.logRecords(includeHEAD: true).makeAsyncIterator()
        return GitParse.commit(try #require(try await it.next()))!
    }

    private func subjects() async throws -> [String] {
        try await git.runString(["log", "--format=%s"], in: dir).split(separator: "\n").map(String.init)
    }

    @Test func tags() async throws {
        let repo = try await Repository.open(dir)
        #expect(await repo.validateTagName("v1.0") == nil)
        #expect(await repo.validateTagName("bad tag") != nil)
        try await repo.createTag("light", at: "HEAD~1")
        try await repo.createTag("v1.0", at: "HEAD", message: "Release 1.0")
        let tags = try await repo.refs().filter { $0.kind == .tag }
        #expect(Set(tags.map(\.name)) == ["light", "v1.0"])
        let type = try await git.runString(["cat-file", "-t", "v1.0"], in: dir)
        #expect(type.hasPrefix("tag"))
        try await repo.deleteTag("light")
        #expect(try await repo.refs().filter { $0.kind == .tag }.map(\.name) == ["v1.0"])
    }

    @Test func cherryPickAndRevert() async throws {
        let repo = try await Repository.open(dir)
        _ = try await git.run(["switch", "-qc", "side", "HEAD~1"], in: dir)
        try await commit("b.txt", "b", "side work")
        let side = try await head(repo)
        _ = try await git.run(["switch", "-q", "main"], in: dir)

        try await repo.cherryPick(side)
        #expect(try await subjects().first == "side work")

        let picked = try await head(repo)
        try await repo.revert(picked)
        #expect(try await subjects().first == "Revert \"side work\"")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
    }

    @Test func resetModes() async throws {
        let repo = try await Repository.open(dir)
        try await repo.reset(.soft, to: "HEAD~1")
        #expect(try await repo.status().first { $0.path == "a.txt" }?.isStaged == true)
        try await repo.reset(.mixed, to: "HEAD")
        let st = try #require(try await repo.status().first { $0.path == "a.txt" })
        #expect(!st.isStaged && st.isUnstaged)
        try await repo.reset(.hard, to: "HEAD")
        #expect(try await repo.status().isEmpty)
        #expect(try await subjects() == ["one"])
    }
}

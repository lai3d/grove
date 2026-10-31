import Foundation
import Testing

@testable import GroveCore

@Suite struct LFSTests {
    @Test func pointerParsing() throws {
        let p = try #require(LFSPointer("version https://git-lfs.github.com/spec/v1\noid sha256:abc123\nsize 2048\n"))
        #expect(p.oid == "abc123" && p.size == 2048)
        #expect(LFSPointer("just text") == nil)
        let diff = try #require(DiffParser.parse("""
        diff --git a/big.bin b/big.bin
        --- a/big.bin
        +++ b/big.bin
        @@ -1,3 +1,3 @@
         version https://git-lfs.github.com/spec/v1
        -oid sha256:aaa
        -size 10
        +oid sha256:bbb
        +size 20

        """).first)
        let change = try #require(diff.lfsChange)
        #expect(change.old?.oid == "aaa" && change.new?.size == 20)
        #expect(DiffParser.parse("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n").first?.lfsChange == nil)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/git-lfs")
                   || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/git-lfs")))
    func realLFSRepository() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-lfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = Git()
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"], ["lfs", "install", "--local"], ["lfs", "track", "*.bin"]] {
            _ = try await git.run(args, in: dir)
        }
        try Data(repeating: 7, count: 5000).write(to: dir.appendingPathComponent("big.bin"))
        try "text\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: dir)
        _ = try await git.run(["commit", "-qm", "add"], in: dir)
        try Data(repeating: 8, count: 6000).write(to: dir.appendingPathComponent("big.bin"))
        _ = try await git.run(["commit", "-qam", "grow"], in: dir)

        let repo = try await Repository.open(dir)
        #expect(repo.usesLFS)
        #expect(await repo.lfsInstalled())
        #expect(await repo.lfsPaths(["big.bin", "a.txt"]) == ["big.bin"])

        let head = try #require(try await repo.commit("HEAD"))
        let file = try #require(try await repo.changedFiles(in: head).first)
        let diff = try #require(DiffParser.parse(try await repo.diff(of: file, in: head)).first)
        let change = try #require(diff.lfsChange)
        #expect(change.old?.size == 5000 && change.new?.size == 6000)
    }
}

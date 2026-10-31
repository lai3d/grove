import Foundation
import Testing

@testable import GroveCore

@Suite struct ContentSearchTests {
    @Test func pickaxeAndRegex() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = Git()
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
        var ids: [String] = []
        for (msg, content) in [("add", "let token = fetchToken()\n"), ("edit", "let token = fetchToken(retry: 3)\n"),
                               ("remove", "// nothing\n"), ("other", "// nothing\nprint(1)\n")] {
            try content.write(to: dir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
            _ = try await git.run(["add", "."], in: dir)
            _ = try await git.run(["commit", "-qm", msg], in: dir)
            ids.append(try await git.runString(["rev-parse", "HEAD"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let repo = try await Repository.open(dir)
        // -S: count of "fetchToken" changed → added (0→1) and removed (1→0); not "edit" (1→1).
        #expect(try await repo.searchContent("fetchToken", regex: false) == [ids[0], ids[2]])
        // -G: any changed line matching → add, edit, remove.
        #expect(try await repo.searchContent("fetchToken\\(retry", regex: true) == [ids[1], ids[2]])
        #expect(try await repo.searchContent("print", regex: false, path: "a.swift") == [ids[3]])
        #expect(try await repo.searchContent("nope-nothing", regex: false).isEmpty)
    }
}

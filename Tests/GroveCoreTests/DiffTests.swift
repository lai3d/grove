import Foundation
import Testing

@testable import GroveCore

@Suite struct DiffParserTests {
    static let sample = """
    diff --git a/f.txt b/f.txt
    index 1111111..2222222 100644
    --- a/f.txt
    +++ b/f.txt
    @@ -1,4 +1,4 @@ func top()
     a
    -b
    +B
     c
     d
    @@ -10 +10,2 @@
     j
    +k
    \\ No newline at end of file

    """

    @Test func parsesHunksAndLineNumbers() throws {
        let files = DiffParser.parse(Self.sample)
        let f = try #require(files.first)
        #expect(files.count == 1 && f.oldPath == "f.txt" && f.newPath == "f.txt" && !f.isBinary)
        #expect(f.hunks.count == 2)
        let h = f.hunks[0]
        #expect(h.oldStart == 1 && h.oldCount == 4 && h.newStart == 1 && h.newCount == 4 && h.section == " func top()")
        #expect(h.lines.map(\.kind) == [.context, .removed, .added, .context, .context])
        #expect(h.lines[1].oldNumber == 2 && h.lines[1].newNumber == nil)
        #expect(h.lines[2].newNumber == 2 && h.lines[3].oldNumber == 3 && h.lines[3].newNumber == 3)
        let h2 = f.hunks[1]
        #expect(h2.oldCount == 1 && h2.newCount == 2 && h2.lines.last?.noNewline == true)
    }

    @Test func binaryAndNewFile() throws {
        let bin = DiffParser.parse("diff --git a/i.png b/i.png\nindex 1..2 100644\nBinary files a/i.png and b/i.png differ\n")
        #expect(bin.first?.isBinary == true && bin.first?.hunks.isEmpty == true)
        let new = DiffParser.parse("diff --git a/n b/n\nnew file mode 100644\nindex 0000000..1\n--- /dev/null\n+++ b/n\n@@ -0,0 +1 @@\n+x\n")
        #expect(new.first?.oldPath == nil && new.first?.newPath == "n" && new.first?.hunks.first?.lines.count == 1)
    }

    @Test func partialPatchForward() throws {
        let f = try #require(DiffParser.parse(Self.sample).first)
        // Only the "+B" line: "-b" becomes context, so b stays and B is inserted.
        let p = try #require(f.patch(hunk: 0, selecting: [2]))
        #expect(p.contains("@@ -1,4 +1,5 @@ func top()\n a\n b\n+B\n c\n d\n"))
        #expect(!p.contains("index "))
        // Nothing selected → no patch.
        #expect(f.patch(hunk: 0, selecting: [0, 3]) == nil)
        // No-newline marker follows a kept line.
        #expect(try #require(f.patch(hunk: 1)).hasSuffix("+k\n\\ No newline at end of file\n"))
    }

    @Test func partialPatchReverse() throws {
        let f = try #require(DiffParser.parse(Self.sample).first)
        // Reverse-apply only "-b": the unselected "+B" is kept (context), unselected "-" lines dropped.
        let p = try #require(f.patch(hunk: 0, selecting: [1], reverse: true))
        #expect(p.contains("@@ -1,4 +1,4 @@ func top()\n a\n-b\n B\n c\n d\n") || p.contains(" a\n-b\n B\n"))
    }
}

/// Real `git apply` round trips.
@Suite struct HunkStagingTests {
    let dir: URL
    let git = Git()

    init() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-hunk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: dir)
        }
        try write((1...30).map { "line \($0)" }.joined(separator: "\n") + "\n")
        _ = try await git.run(["add", "."], in: dir)
        _ = try await git.run(["commit", "-qm", "base"], in: dir)
    }

    private func write(_ s: String) throws {
        try s.write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    }

    private func read() throws -> String { try String(contentsOf: dir.appendingPathComponent("f.txt"), encoding: .utf8) }

    private func diff(cached: Bool) async throws -> FileDiff? {
        let text = try await git.runString(cached ? ["diff", "--cached"] : ["diff"], in: dir)
        return DiffParser.parse(text).first
    }

    /// Two separate edits: line 2 → TWO, line 25 → TWENTY-FIVE + extra line.
    private func makeEdits() throws {
        var lines = (1...30).map { "line \($0)" }
        lines[1] = "TWO"
        lines[24] = "TWENTY-FIVE"
        lines.insert("extra", at: 25)
        try write(lines.joined(separator: "\n") + "\n")
    }

    @Test func stageOneHunkThenUnstageIt() async throws {
        try makeEdits()
        let repo = try await Repository.open(dir)
        let unstaged = try #require(try await diff(cached: false))
        #expect(unstaged.hunks.count == 2)

        try await repo.apply(.stage, hunk: 1, in: unstaged)
        let staged = try #require(try await diff(cached: true))
        #expect(staged.hunks.count == 1 && staged.hunks[0].lines.contains { $0.text == "TWENTY-FIVE" })
        #expect(try await diff(cached: false)?.hunks.count == 1)

        try await repo.apply(.unstage, hunk: 0, in: staged)
        #expect(try await diff(cached: true) == nil)
        #expect(try await diff(cached: false)?.hunks.count == 2)
    }

    @Test func stageSingleLines() async throws {
        try makeEdits()
        let repo = try await Repository.open(dir)
        let unstaged = try #require(try await diff(cached: false))
        let h = unstaged.hunks[1]
        // Stage only the inserted "extra" line, not the TWENTY-FIVE replacement.
        let extra = try #require(h.lines.firstIndex { $0.text == "extra" })
        try await repo.apply(.stage, hunk: 1, lines: [extra], in: unstaged)
        let index = try await git.runString(["show", ":f.txt"], in: dir)
        #expect(index.contains("line 25\nextra\nline 26"))
        #expect(!index.contains("TWENTY-FIVE") && !index.contains("TWO"))

        // Unstage that line again from the staged diff.
        let staged = try #require(try await diff(cached: true))
        let idx = try #require(staged.hunks[0].lines.firstIndex { $0.text == "extra" })
        try await repo.apply(.unstage, hunk: 0, lines: [idx], in: staged)
        #expect(try await diff(cached: true) == nil)
        #expect(try read().contains("TWENTY-FIVE\nextra"))  // worktree untouched
    }

    @Test func discardHunkAndLines() async throws {
        try makeEdits()
        let repo = try await Repository.open(dir)
        var unstaged = try #require(try await diff(cached: false))
        try await repo.apply(.discard, hunk: 0, in: unstaged)
        #expect(try read().contains("line 1\nline 2\nline 3"))
        #expect(try read().contains("TWENTY-FIVE"))

        // Discard only the "-line 25"/"+TWENTY-FIVE" pair, keep "extra".
        unstaged = try #require(try await diff(cached: false))
        let h = unstaged.hunks[0]
        let picks = Set(h.lines.indices.filter { h.lines[$0].text == "TWENTY-FIVE" || h.lines[$0].text == "line 25" })
        try await repo.apply(.discard, hunk: 0, lines: picks, in: unstaged)
        #expect(try read().contains("line 24\nline 25\nextra\nline 26"))
    }

    @Test func noNewlineAtEndOfFile() async throws {
        try write((1...30).map { "line \($0)" }.joined(separator: "\n") + "\nlast")  // no trailing newline
        let repo = try await Repository.open(dir)
        let unstaged = try #require(try await diff(cached: false))
        try await repo.apply(.stage, hunk: 0, in: unstaged)
        #expect(try await git.runString(["show", ":f.txt"], in: dir).hasSuffix("line 30\nlast"))
    }
}

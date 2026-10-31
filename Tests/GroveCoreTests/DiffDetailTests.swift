import Foundation
import Testing

@testable import GroveCore

@Suite struct DiffDetailTests {
    private func sub(_ s: String, _ r: NSRange) -> String { (s as NSString).substring(with: r) }

    @Test func wordDiffFindsChangedWords() {
        let old = "let total = price * count", new = "let total = price * quantity + tax"
        let (a, b) = WordDiff.ranges(old: old, new: new)
        #expect(a.map { sub(old, $0) } == ["count"])
        #expect(b.map { sub(new, $0) } == ["quantity + tax"])
    }

    @Test func wordDiffSkipsUnrelatedLines() {
        let (a, b) = WordDiff.ranges(old: "completely different", new: "x = 1")
        #expect(a.isEmpty && b.isEmpty)
    }

    @Test func wordDiffUsesUTF16Offsets() {
        let old = "名前 = \"太郎\"", new = "名前 = \"花子\""
        let (a, b) = WordDiff.ranges(old: old, new: new)
        #expect(a.map { sub(old, $0) } == ["太郎"] && b.map { sub(new, $0) } == ["花子"])
    }

    @Test func splitRowsPairRemovalsWithAdditions() throws {
        let diff = try #require(DiffParser.parse("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,4 +1,4 @@\n a\n-b\n-c\n+B\n d\n+e\n").first)
        let rows = diff.hunks[0].splitRows
        #expect(rows.map { [$0.left?.text ?? "∅", $0.right?.text ?? "∅"] } == [["a", "a"], ["b", "B"], ["c", "∅"], ["d", "d"], ["∅", "e"]])
        #expect(diff.hunks[0].pairs == [1: 3, 3: 1])
    }

    @Test func syntaxTokens() throws {
        let swift = try #require(SyntaxHighlighter.forPath("Sources/A.swift"))
        let line = "let name: String = \"x\" // note"
        let kinds = swift.tokens(line).map { "\(($0.kind)):\(sub(line, $0.range))" }
        #expect(kinds == ["keyword:let", "type:String", "string:\"x\"", "comment:// note"])
        let py = try #require(SyntaxHighlighter.forPath("a.py"))
        #expect(py.tokens("return 42  # done").map(\.kind) == [.keyword, .number, .comment])
        #expect(SyntaxHighlighter.forPath("notes.unknownext") == nil)
        let str = swift.tokens("print(\"a \\\" b\")")
        #expect(str.count == 1 && sub("print(\"a \\\" b\")", str[0].range) == "\"a \\\" b\"")
    }
}

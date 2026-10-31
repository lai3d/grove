import Foundation
import Testing

@testable import GroveCore

@Suite struct ParserTests {
    @Test func decorations() {
        let refs = GitParse.decorations("HEAD -> refs/heads/main, refs/remotes/origin/main, refs/remotes/origin/HEAD, tag: refs/tags/v1.0, refs/heads/feature/x")
        #expect(refs == [
            RefLabel(kind: .branch, name: "main", isCurrent: true),
            RefLabel(kind: .remote, name: "origin/main"),
            RefLabel(kind: .tag, name: "v1.0"),
            RefLabel(kind: .branch, name: "feature/x"),
        ])
        #expect(GitParse.decorations("HEAD") == [RefLabel(kind: .head, name: "HEAD", isCurrent: true)])
        #expect(GitParse.decorations("").isEmpty)
    }

    @Test func commitRecord() throws {
        let rec = "abc123\u{1f}p1 p2\u{1f}Ada Lovelace\u{1f}ada@example.com\u{1f}1700000000\u{1f}Fix: 中文 subject\u{1f}tag: refs/tags/v2"
        let c = try #require(GitParse.commit(Data(rec.utf8)))
        #expect(c.id == "abc123" && c.parents == ["p1", "p2"] && c.isMerge)
        #expect(c.authorName == "Ada Lovelace" && c.authorEmail == "ada@example.com")
        #expect(c.date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(c.subject == "Fix: 中文 subject")
        #expect(c.refs == [RefLabel(kind: .tag, name: "v2")])
    }

    @Test func rootCommitRecord() throws {
        let c = try #require(GitParse.commit(Data("\nabc\u{1f}\u{1f}A\u{1f}a@x\u{1f}1\u{1f}init\u{1f}".utf8)))
        #expect(c.id == "abc" && c.parents.isEmpty && c.refs.isEmpty && c.subject == "init")
    }

    @Test func statusPorcelainV2() {
        let raw = [
            "1 M. N... 100644 100644 100644 aaa bbb staged file.txt",
            "1 .M N... 100644 100644 100644 aaa aaa dir/unstaged.txt",
            "2 R. N... 100644 100644 100644 aaa aaa R100 new name.txt", "old name.txt",
            "u UU N... 100644 100644 100644 100644 a b c conflict.txt",
            "? untracked.txt",
            "! ignored.txt",
        ].joined(separator: "\0") + "\0"
        let s = GitParse.status(Data(raw.utf8))
        #expect(s.map(\.path) == ["staged file.txt", "dir/unstaged.txt", "new name.txt", "conflict.txt", "untracked.txt"])
        #expect(s[0].isStaged && !s[0].isUnstaged)
        #expect(!s[1].isStaged && s[1].isUnstaged)
        #expect(s[2].kind == .renamed && s[2].origPath == "old name.txt" && s[2].isStaged)
        #expect(s[3].kind == .unmerged && s[3].isUnstaged && !s[3].isStaged)
        #expect(s[4].kind == .untracked && s[4].isUnstaged)
    }

    @Test func nameStatus() {
        let raw = ["M", "a.txt", "R087", "old.txt", "new.txt", "A", "b c.txt"].joined(separator: "\0") + "\0"
        let files = GitParse.nameStatus(Data(raw.utf8))
        #expect(files == [
            ChangedFile(status: "M", path: "a.txt", origPath: nil),
            ChangedFile(status: "R087", path: "new.txt", origPath: "old.txt"),
            ChangedFile(status: "A", path: "b c.txt", origPath: nil),
        ])
    }

    @Test func refs() {
        let raw = [
            "refs/heads/main\u{1f}aaa\u{1f}\u{1f}origin/main\u{1f}[ahead 1]",
            "refs/remotes/origin/HEAD\u{1f}aaa\u{1f}\u{1f}\u{1f}",
            "refs/remotes/origin/main\u{1f}bbb\u{1f}\u{1f}\u{1f}",
            "refs/tags/v1\u{1f}tagobj\u{1f}ccc\u{1f}\u{1f}",
        ].joined(separator: "\n")
        let r = GitParse.refs(Data(raw.utf8))
        #expect(r.map(\.name) == ["main", "origin/main", "v1"])
        #expect(r[0].upstream == "origin/main" && r[0].track == "[ahead 1]")
        #expect(r[2].target == "ccc")  // annotated tag peeled to its commit
    }
}

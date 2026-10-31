import Testing

@testable import GroveCore

@Suite struct FuzzyTests {
    @Test func matchesSubsequences() {
        #expect(Fuzzy.score("fl", "feature/login") != nil)
        #expect(Fuzzy.score("FEAT", "feature/login") != nil)
        #expect(Fuzzy.score("xyz", "feature/login") == nil)
        #expect(Fuzzy.score("", "anything") == 0)
    }

    @Test func ranksWordStartsAndRunsHigher() throws {
        let q = "fl"
        let wordStarts = try #require(Fuzzy.score(q, "feature/login"))
        let buried = try #require(Fuzzy.score(q, "fileupload"))
        #expect(wordStarts > buried)

        let run = try #require(Fuzzy.score("push", "Push"))
        let scattered = try #require(Fuzzy.score("push", "Pull with rebase, stash"))
        #expect(run > scattered)

        let camel = try #require(Fuzzy.score("nb", "NewBranch"))
        let flat = try #require(Fuzzy.score("nb", "newbranch"))
        #expect(camel > flat)
    }

    @Test func shorterWinsTies() throws {
        #expect(try #require(Fuzzy.score("main", "main")) > (try #require(Fuzzy.score("main", "origin/main-old-backup"))))
    }
}

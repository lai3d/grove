import Foundation
import Testing

@testable import GroveCore

@Suite struct PullRequestTests {
    @Test func numbersAndRefs() throws {
        #expect(HostedRepo.pullRequestNumber(from: " 42 ") == 42)
        #expect(HostedRepo.pullRequestNumber(from: "#42") == 42)
        #expect(HostedRepo.pullRequestNumber(from: "!7") == 7)
        #expect(HostedRepo.pullRequestNumber(from: "https://github.com/o/r/pull/123/files") == 123)
        #expect(HostedRepo.pullRequestNumber(from: "https://gitlab.com/g/p/-/merge_requests/9") == 9)
        #expect(HostedRepo.pullRequestNumber(from: "abc") == nil)
        #expect(HostedRepo.pullRequestNumber(from: "0") == nil)
        let gh = try #require(HostedRepo(remoteURL: "git@github.com:o/r.git"))
        #expect(gh.pullRequestRef(5) == "refs/pull/5/head" && gh.pullRequestBranch(5) == "pr/5")
        let gl = try #require(HostedRepo(remoteURL: "https://gitlab.com/g/p.git"))
        #expect(gl.pullRequestRef(5) == "refs/merge-requests/5/head" && gl.pullRequestBranch(5) == "mr/5")
        #expect(HostedRepo(remoteURL: "git@bitbucket.org:o/r.git")?.pullRequestRef(5) == nil)
        #expect(gh.pullRequest(5).absoluteString == "https://github.com/o/r/pull/5")
        #expect(gl.pullRequest(5).absoluteString == "https://gitlab.com/g/p/-/merge_requests/5")
    }

    @Test func checkOutAndUpdatePullRequest() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("grove-pr-\(UUID().uuidString)")
        let server = base.appendingPathComponent("server"), clone = base.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
        let git = Git()
        func run(_ args: [String], _ dir: URL) async throws { _ = try await git.run(args, in: dir) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@x"],
                     ["config", "commit.gpgsign", "false"], ["commit", "-q", "--allow-empty", "-m", "base"],
                     ["switch", "-qc", "contrib"], ["commit", "-q", "--allow-empty", "-m", "pr one"],
                     ["update-ref", "refs/pull/7/head", "HEAD"], ["switch", "-q", "main"]] {
            try await run(args, server)
        }
        try await run(["clone", "-q", server.path, clone.path], base)
        let repo = try await Repository.open(clone)
        try await repo.checkOutRemoteRef("refs/pull/7/head", from: "origin", as: "pr/7") { _ in }
        #expect(await repo.currentBranch() == "pr/7")
        #expect(try await git.runString(["log", "-1", "--format=%s"], in: clone) == "pr one\n")

        // The author pushes again: checking out again fast-forwards the current branch.
        try await run(["switch", "-q", "contrib"], server)
        try await run(["commit", "-q", "--allow-empty", "-m", "pr two"], server)
        try await run(["update-ref", "refs/pull/7/head", "HEAD"], server)
        try await repo.checkOutRemoteRef("refs/pull/7/head", from: "origin", as: "pr/7") { _ in }
        #expect(try await git.runString(["log", "-1", "--format=%s"], in: clone) == "pr two\n")

        // A local commit on pr/7 that the request doesn't have is never thrown away.
        for args in [["config", "user.name", "T"], ["config", "user.email", "t@x"], ["config", "commit.gpgsign", "false"],
                     ["commit", "-q", "--allow-empty", "-m", "mine"], ["switch", "-q", "main"]] {
            try await run(args, clone)
        }
        await #expect(throws: GitError.self) {
            try await repo.checkOutRemoteRef("refs/pull/7/head", from: "origin", as: "pr/7") { _ in }
        }
        #expect(await repo.currentBranch() == "main")
        await #expect(throws: GitError.self) {
            try await repo.checkOutRemoteRef("refs/pull/99/head", from: "origin", as: "pr/99") { _ in }
        }
    }
}

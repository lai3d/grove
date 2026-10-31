import Foundation
import Testing

@testable import GroveCore

@Suite struct HostingTests {
    @Test func parsesRemoteURLForms() throws {
        for url in ["git@github.com:lai3d/grove.git", "https://github.com/lai3d/grove.git", "https://user:tok@github.com/lai3d/grove",
                    "ssh://git@github.com/lai3d/grove.git", "ssh://git@ssh.github.com:443/lai3d/grove.git"] {
            let h = try #require(HostedRepo(remoteURL: url), "\(url)")
            #expect(h.host == .github && h.web.absoluteString == "https://github.com/lai3d/grove", "\(url)")
        }
        let gl = try #require(HostedRepo(remoteURL: "git@gitlab.example.com:group/sub/proj.git"))
        #expect(gl.host == .gitlab && gl.web.absoluteString == "https://gitlab.example.com/group/sub/proj")
        #expect(HostedRepo(remoteURL: "/local/path/repo.git") == nil)
        #expect(HostedRepo(remoteURL: "git@example.com:o/r.git") == nil)
    }

    @Test func buildsWebURLs() throws {
        let gh = try #require(HostedRepo(remoteURL: "git@github.com:o/r.git"))
        #expect(gh.commit("abc").absoluteString == "https://github.com/o/r/commit/abc")
        #expect(gh.branch("feature/x").absoluteString == "https://github.com/o/r/tree/feature/x")
        #expect(gh.file("Sources/A B.swift", at: "abc").absoluteString == "https://github.com/o/r/blob/abc/Sources/A%20B.swift")
        #expect(gh.newPullRequest(from: "feature/x").absoluteString == "https://github.com/o/r/pull/new/feature/x")
        #expect(gh.newPullRequest(from: "f", into: "main").absoluteString == "https://github.com/o/r/compare/main...f?expand=1")

        let gl = try #require(HostedRepo(remoteURL: "https://gitlab.com/g/p.git"))
        #expect(gl.commit("abc").absoluteString == "https://gitlab.com/g/p/-/commit/abc")
        #expect(gl.newPullRequest(from: "a&b").absoluteString
            == "https://gitlab.com/g/p/-/merge_requests/new?merge_request%5Bsource_branch%5D=a%26b")

        let bb = try #require(HostedRepo(remoteURL: "git@bitbucket.org:t/r.git"))
        #expect(bb.branch("dev").absoluteString == "https://bitbucket.org/t/r/src/dev")
    }

    @Test func picksUpstreamRemote() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = Git()
        _ = try await git.run(["init", "-q"], in: dir)
        _ = try await git.run(["remote", "add", "fork", "git@github.com:me/r.git"], in: dir)
        _ = try await git.run(["remote", "add", "origin", "git@github.com:org/r.git"], in: dir)
        let repo = try await Repository.open(dir)
        #expect(await repo.hostedRepo()?.web.absoluteString == "https://github.com/org/r")
        #expect(await repo.hostedRepo(preferring: "fork")?.web.absoluteString == "https://github.com/me/r")
    }
}

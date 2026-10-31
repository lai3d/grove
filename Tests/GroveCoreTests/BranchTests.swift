import Foundation
import Testing

@testable import GroveCore

@Suite struct BranchTests {
    let dir: URL
    let origin: URL
    let git = Git()

    init() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("grove-branch-\(UUID().uuidString)")
        origin = base.appendingPathComponent("origin")
        dir = base.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try await sh(origin, "init", "-q", "-b", "main")
        for d in [origin] { try await configure(d) }
        try "1".write(to: origin.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        try await sh(origin, "add", ".")
        try await sh(origin, "commit", "-qm", "one")
        try await sh(origin, "branch", "remote-only")
        _ = try await git.run(["clone", "-q", origin.path, dir.path], in: base)
        try await configure(dir)
    }

    private func configure(_ d: URL) async throws {
        try await sh(d, "config", "user.name", "T")
        try await sh(d, "config", "user.email", "t@x")
        try await sh(d, "config", "commit.gpgsign", "false")
    }

    @discardableResult
    private func sh(_ d: URL, _ args: String...) async throws -> String {
        try await git.runString(args, in: d)
    }

    @Test func createRenameDeleteAndCheckout() async throws {
        let repo = try await Repository.open(dir)
        #expect(await repo.validateBranchName("feature/ok") == nil)
        #expect(await repo.validateBranchName("bad..name") != nil)
        #expect(await repo.validateBranchName("") != nil)

        try await repo.createBranch("topic", at: "HEAD", checkout: false)
        #expect(await repo.currentBranch() == "main")
        try await repo.createBranch("work", at: "HEAD", checkout: true)
        #expect(await repo.currentBranch() == "work")

        try await repo.renameBranch("topic", to: "topic2")
        let names = Set(try await repo.refs().filter { $0.kind == .branch }.map(\.name))
        #expect(names == ["main", "work", "topic2"])

        try await repo.deleteBranch("topic2", force: false)
        #expect(try await repo.refs().contains { $0.name == "topic2" } == false)

        // Unmerged work needs force.
        try "2".write(to: dir.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        try await sh(dir, "commit", "-qam", "two")
        try await sh(dir, "switch", "-q", "main")
        do {
            try await repo.deleteBranch("work", force: false)
            Issue.record("expected failure")
        } catch let e as GitError {
            #expect(e.isNotFullyMerged)
        }
        try await repo.deleteBranch("work", force: true)
    }

    @Test func checkoutRemoteCreatesTrackingBranch() async throws {
        let repo = try await Repository.open(dir)
        let remote = try #require(try await repo.refs().first { $0.kind == .remote && $0.name == "origin/remote-only" })
        try await repo.checkout(remote)
        #expect(await repo.currentBranch() == "remote-only")
        let local = try #require(try await repo.refs().first { $0.kind == .branch && $0.name == "remote-only" })
        #expect(local.upstream == "origin/remote-only")
        // Second time: just switches to the existing local branch.
        try await sh(dir, "switch", "-q", "main")
        try await repo.checkout(remote)
        #expect(await repo.currentBranch() == "remote-only")

        let tag = Ref(fullName: "refs/heads/main", kind: .branch, name: "main", target: "", upstream: nil, track: "")
        try await repo.checkout(tag)
        #expect(await repo.currentBranch() == "main")
    }
}

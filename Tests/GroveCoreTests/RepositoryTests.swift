import Foundation
import Testing

@testable import GroveCore

/// End-to-end against a throwaway repository built with the real git binary.
@Suite struct RepositoryTests {
    let dir: URL
    let git = Git()

    init() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await sh("init", "-q", "-b", "main")
        try await sh("config", "user.name", "Test")
        try await sh("config", "user.email", "test@example.com")
        try await sh("config", "commit.gpgsign", "false")
        try await sh("config", "tag.gpgsign", "false")
    }

    @discardableResult
    private func sh(_ args: String...) async throws -> String {
        try await git.runString(args, in: dir)
    }

    private func write(_ name: String, _ content: String) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commits(_ repo: Repository) async throws -> [Commit] {
        var out: [Commit] = []
        for try await r in repo.logRecords(includeHEAD: await repo.hasHEAD()) {
            if let c = GitParse.commit(r) { out.append(c) }
        }
        return out
    }

    @Test func emptyRepository() async throws {
        let repo = try await Repository.open(dir)
        #expect(await repo.hasHEAD() == false)
        #expect(try await commits(repo).isEmpty)
        #expect(await repo.currentBranch() == "main")
    }

    @Test func historyWithMergeAndRefs() async throws {
        try write("a.txt", "a\n")
        try await sh("add", ".")
        try await sh("commit", "-qm", "root")
        try await sh("switch", "-qc", "feature")
        try write("b.txt", "b\n")
        try await sh("add", ".")
        try await sh("commit", "-qm", "feature work")
        try await sh("switch", "-q", "main")
        try write("a.txt", "a2\n")
        try await sh("commit", "-qam", "main work")
        try await sh("merge", "-q", "--no-ff", "-m", "merge feature", "feature")
        try await sh("tag", "-a", "v1", "-m", "release")

        let repo = try await Repository.open(dir.appendingPathComponent("."))
        let log = try await commits(repo)
        #expect(log.map(\.subject) == ["merge feature", "main work", "feature work", "root"]
             || log.map(\.subject) == ["merge feature", "feature work", "main work", "root"])
        let merge = log[0]
        #expect(merge.isMerge)
        #expect(merge.refs.contains(RefLabel(kind: .branch, name: "main", isCurrent: true)))
        #expect(merge.refs.contains(RefLabel(kind: .tag, name: "v1")))

        var layout = GraphLayout()
        let rows = log.map { layout.add(id: $0.id, parents: $0.parents) }
        #expect(rows.map(\.width).max() == 2)

        let refs = try await repo.refs()
        #expect(Set(refs.map(\.name)) == ["main", "feature", "v1"])
        #expect(refs.first { $0.name == "v1" }?.target == merge.id)

        let rootCommit = try #require(log.last)
        let rootFiles = try await repo.changedFiles(in: rootCommit)
        #expect(rootFiles == [ChangedFile(status: "A", path: "a.txt", origPath: nil)])
        let rootDiff = try await repo.diff(of: rootFiles[0], in: rootCommit)
        #expect(rootDiff.contains("+a"))

        let mergeFiles = try await repo.changedFiles(in: merge)
        #expect(mergeFiles.map(\.path) == ["b.txt"])
        #expect(try await repo.message(of: merge.id).hasPrefix("merge feature"))
    }

    @Test func stageUnstageAndCommit() async throws {
        try write("tracked.txt", "1\n")
        let repo = try await Repository.open(dir)

        // Unstaging before the first commit must work too.
        try await repo.stage(["tracked.txt"])
        #expect(try await repo.status().first?.isStaged == true)
        try await repo.unstage(["tracked.txt"])
        #expect(try await repo.status().first?.kind == .untracked)

        let untracked = try #require(try await repo.status().first)
        #expect(try await repo.workingDiff(of: untracked, staged: false).contains("+1"))

        try await repo.stage(["tracked.txt"])
        try await repo.commit(message: "first\n\nbody line")
        #expect(try await repo.status().isEmpty)
        #expect(try await repo.message(of: "HEAD").trimmingCharacters(in: .whitespacesAndNewlines) == "first\n\nbody line")

        try write("tracked.txt", "2\n")
        try write("dir/new file.txt", "x\n")
        var status = try await repo.status()
        #expect(Set(status.map(\.path)) == ["tracked.txt", "dir/new file.txt"])
        let modified = try #require(status.first { $0.path == "tracked.txt" })
        #expect(try await repo.workingDiff(of: modified, staged: false).contains("+2"))

        try await repo.stage(["tracked.txt"])
        status = try await repo.status()
        let staged = try #require(status.first { $0.path == "tracked.txt" })
        #expect(staged.isStaged && !staged.isUnstaged)
        #expect(try await repo.workingDiff(of: staged, staged: true).contains("-1"))
        try await repo.unstage(["tracked.txt"])
        #expect(try await repo.status().first { $0.path == "tracked.txt" }?.isStaged == false)
    }

    @Test func gitErrorsSurface() async throws {
        let repo = try await Repository.open(dir)
        await #expect(throws: GitError.self) { try await repo.message(of: "does-not-exist") }
        let notRepo = FileManager.default.temporaryDirectory.appendingPathComponent("grove-norepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: notRepo, withIntermediateDirectories: true)
        await #expect(throws: GitError.self) { try await Repository.open(notRepo) }
    }
}

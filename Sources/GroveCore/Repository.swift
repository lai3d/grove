import Foundation

/// One working tree. Reads are `nonisolated` and may run in parallel; writes are
/// actor-isolated so they're serialized per repository (no index.lock races
/// between our own operations).
public actor Repository {
    public nonisolated let root: URL
    public nonisolated let git: Git

    init(root: URL, git: Git) {
        self.root = root
        self.git = git
    }

    public static func open(_ url: URL, git: Git = Git()) async throws -> Repository {
        let top = try await git.runString(["rev-parse", "--show-toplevel"], in: url)
            .trimmingCharacters(in: .newlines)
        return Repository(root: URL(fileURLWithPath: top), git: git)
    }

    public nonisolated var name: String { root.lastPathComponent }

    // MARK: Reads

    public nonisolated func hasHEAD() async -> Bool {
        let out = try? await git.runString(["rev-parse", "-q", "--verify", "HEAD^{commit}"], in: root, okExitCodes: [0, 1])
        return !(out ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public nonisolated func currentBranch() async -> String? {
        let out = try? await git.runString(["symbolic-ref", "--short", "-q", "HEAD"], in: root, okExitCodes: [0, 1])
        let b = (out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? nil : b
    }

    /// Raw `git log -z` records for all refs, in topo order; parse with `GitParse.commit`.
    public nonisolated func logRecords(includeHEAD: Bool) -> AsyncThrowingStream<Data, Error> {
        var args = ["log", "-z", "--topo-order", "--decorate=full", GitParse.logFormat]
        if includeHEAD { args.append("HEAD") }
        args += ["--branches", "--remotes", "--tags"]
        return git.records(args, in: root)
    }

    public nonisolated func refs() async throws -> [Ref] {
        GitParse.refs(try await git.run(["for-each-ref", GitParse.refFormat, "refs/heads", "refs/remotes", "refs/tags"], in: root))
    }

    public nonisolated func status() async throws -> [FileChange] {
        GitParse.status(try await git.run(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: root))
    }

    public nonisolated func message(of id: String) async throws -> String {
        try await git.runString(["show", "-s", "--format=%B", id], in: root)
    }

    public nonisolated func changedFiles(in commit: Commit) async throws -> [ChangedFile] {
        let args: [String] = if let parent = commit.parents.first {
            ["diff", "-z", "-M", "--name-status", "--no-ext-diff", parent, commit.id]
        } else {
            ["diff-tree", "--root", "--no-commit-id", "-r", "-z", "-M", "--name-status", commit.id]
        }
        return GitParse.nameStatus(try await git.run(args, in: root))
    }

    /// Patch for one file of a commit, against its first parent.
    public nonisolated func diff(of file: ChangedFile, in commit: Commit) async throws -> String {
        let base: String = if let parent = commit.parents.first { parent } else { try await emptyTree() }
        var paths = [file.path]
        if let orig = file.origPath { paths.insert(orig, at: 0) }
        return try await git.runString(["diff", "-M", "--no-ext-diff", base, commit.id, "--"] + paths, in: root)
    }

    public nonisolated func workingDiff(of change: FileChange, staged: Bool) async throws -> String {
        if change.kind == .untracked {
            // --no-index exits 1 when files differ.
            return try await git.runString(["diff", "--no-ext-diff", "--no-index", "--", "/dev/null", change.path],
                                           in: root, okExitCodes: [0, 1])
        }
        var paths = [change.path]
        if let orig = change.origPath, staged { paths.insert(orig, at: 0) }
        let args = staged ? ["diff", "--cached", "-M", "--no-ext-diff", "--"] : ["diff", "--no-ext-diff", "--"]
        return try await git.runString(args + paths, in: root)
    }

    private nonisolated func emptyTree() async throws -> String {
        try await git.runString(["hash-object", "-t", "tree", "--stdin"], in: root, input: Data())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Writes

    public func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await git.run(["add", "-A", "--"] + paths, in: root)
    }

    public func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        if await hasHEAD() {
            _ = try await git.run(["reset", "-q", "--"] + paths, in: root)
        } else {
            _ = try await git.run(["rm", "--cached", "-q", "-r", "--"] + paths, in: root)
        }
    }

    /// Runs `git commit` so hooks and commit signing apply.
    public func commit(message: String) async throws {
        _ = try await git.run(["commit", "-F", "-"], in: root, input: Data(message.utf8))
    }
}

import Foundation

/// One working tree. Reads are `nonisolated` and may run in parallel; writes are
/// actor-isolated so they're serialized per repository (no index.lock races
/// between our own operations).
public actor Repository {
    public nonisolated let root: URL
    public nonisolated let git: Git
    /// `.git` of this working tree, and the common dir holding refs (differs for linked worktrees).
    public nonisolated let gitDir: URL
    public nonisolated let commonDir: URL

    init(root: URL, gitDir: URL, commonDir: URL, git: Git) {
        self.root = root
        self.gitDir = gitDir
        self.commonDir = commonDir
        self.git = git
    }

    public static func open(_ url: URL, git: Git = Git()) async throws -> Repository {
        let out = try await git.runString(["rev-parse", "--path-format=absolute", "--show-toplevel",
                                           "--absolute-git-dir", "--git-common-dir"], in: url)
        let lines = out.split(separator: "\n").map(String.init)
        guard lines.count >= 3 else {
            throw GitError(arguments: ["rev-parse"], exitCode: 0, stderr: "unexpected rev-parse output: \(out)")
        }
        return Repository(root: URL(fileURLWithPath: lines[0]), gitDir: URL(fileURLWithPath: lines[1]),
                          commonDir: URL(fileURLWithPath: lines[2]), git: git)
    }

    /// Starts watching this repository; keep the returned watcher alive.
    public nonisolated func watch(_ handler: @escaping @Sendable (RepositoryWatcher.Change) -> Void) -> RepositoryWatcher {
        let w = RepositoryWatcher(root: root, gitDirs: [gitDir, commonDir], handler: handler)
        w.start()
        return w
    }

    public nonisolated var name: String { root.lastPathComponent }

    // MARK: Reads

    public nonisolated func hasHEAD() async -> Bool {
        await headID() != nil
    }

    /// Commit HEAD points at, nil on an unborn branch.
    public nonisolated func headID() async -> String? {
        let out = try? await git.runString(["rev-parse", "-q", "--verify", "HEAD^{commit}"], in: root, okExitCodes: [0, 1])
        let id = (out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    public nonisolated func currentBranch() async -> String? {
        let out = try? await git.runString(["symbolic-ref", "--short", "-q", "HEAD"], in: root, okExitCodes: [0, 1])
        let b = (out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? nil : b
    }

    /// Raw `git log -z` records for all refs, in topo order; parse with `GitParse.commit`.
    /// With `path`, only commits touching it, with parents rewritten (`--parents`) so the
    /// graph of the simplified history stays connected.
    public nonisolated func logRecords(includeHEAD: Bool, path: String? = nil) -> AsyncThrowingStream<Data, Error> {
        var args = ["log", "-z", "--topo-order", "--decorate=full", GitParse.logFormat]
        if path != nil { args.append("--parents") }
        if includeHEAD { args.append("HEAD") }
        args += ["--branches", "--remotes", "--tags"]
        if let path { args += ["--", path] }
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
    public func commit(message: String, amend: Bool = false, signOff: Bool = false) async throws {
        var args = ["commit", "-F", "-"]
        if amend { args.append("--amend") }
        if signOff { args.append("--signoff") }
        _ = try await git.run(args, in: root, input: Data(message.utf8))
    }

    /// True when HEAD is already contained in its branch's upstream (amending would rewrite published history).
    public nonisolated func isHeadPushed() async -> Bool {
        (try? await git.run(["merge-base", "--is-ancestor", "HEAD", "@{upstream}"], in: root)) != nil
    }

    // MARK: Branches

    /// nil when `name` is a valid branch name, else git's complaint.
    public nonisolated func validateBranchName(_ name: String) async -> String? {
        if name.isEmpty { return "Name is empty" }
        do {
            _ = try await git.run(["check-ref-format", "--branch", name], in: root)
            return nil
        } catch {
            return "“\(name)” is not a valid branch name"
        }
    }

    /// Switches to a local branch, or for a remote branch to a local tracking
    /// branch of the same name (created if missing).
    public func checkout(_ ref: Ref) async throws {
        switch ref.kind {
        case .branch:
            _ = try await git.run(["switch", "--no-guess", ref.name], in: root)
        case .remote:
            let local = ref.name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? ref.name
            let exists = (try? await git.run(["rev-parse", "-q", "--verify", "refs/heads/\(local)"], in: root)) != nil
            if exists {
                _ = try await git.run(["switch", "--no-guess", local], in: root)
            } else {
                _ = try await git.run(["switch", "--track", ref.name], in: root)
            }
        case .tag:
            _ = try await git.run(["switch", "--detach", ref.fullName], in: root)
        }
    }

    public func checkoutDetached(_ commitID: String) async throws {
        _ = try await git.run(["switch", "--detach", commitID], in: root)
    }

    public func createBranch(_ name: String, at startPoint: String, checkout: Bool) async throws {
        if checkout {
            _ = try await git.run(["switch", "-c", name, startPoint], in: root)
        } else {
            _ = try await git.run(["branch", "--no-track", name, startPoint], in: root)
        }
    }

    public func renameBranch(_ old: String, to new: String) async throws {
        _ = try await git.run(["branch", "-m", old, new], in: root)
    }

    /// Throws `GitError` with `isNotFullyMerged` when `force` is false and the branch has unmerged work.
    public func deleteBranch(_ name: String, force: Bool) async throws {
        _ = try await git.run(["branch", force ? "-D" : "-d", name], in: root)
    }

    // MARK: Remotes

    public nonisolated func remotes() async throws -> [String] {
        try await git.runString(["remote"], in: root).split(separator: "\n").map(String.init)
    }

    public func fetch(progress: @escaping @Sendable (String) -> Void) async throws {
        _ = try await git.runWithProgress(["fetch", "--all", "--prune", "--progress"], in: root, progress: progress)
    }

    public enum PullMode: String, Sendable, CaseIterable { case fastForwardOnly, rebase, merge }

    public func pull(_ mode: PullMode, progress: @escaping @Sendable (String) -> Void) async throws {
        let flag = switch mode {
        case .fastForwardOnly: "--ff-only"
        case .rebase: "--rebase"
        case .merge: "--no-rebase"
        }
        _ = try await git.runWithProgress(["pull", flag, "--progress"], in: root, progress: progress)
    }

    /// Pushes the current branch; without an upstream it is published to `remote`
    /// (default: the only remote, else "origin") and tracking is set up.
    public func push(force: Bool = false, remote: String? = nil, progress: @escaping @Sendable (String) -> Void) async throws {
        guard let branch = await currentBranch() else {
            throw GitError(arguments: ["push"], exitCode: 1, stderr: "HEAD is detached — check out a branch to push")
        }
        var args = ["push", "--progress"]
        if force { args.append("--force-with-lease") }
        let upstream = try? await git.runString(["rev-parse", "--abbrev-ref", "\(branch)@{upstream}"], in: root)
        if upstream?.isEmpty ?? true {
            let all = try await remotes()
            guard let target = remote ?? (all.count == 1 ? all[0] : all.first { $0 == "origin" }) else {
                throw GitError(arguments: ["push"], exitCode: 1, stderr: "No remote to push to")
            }
            args += ["-u", target, branch]
        }
        _ = try await git.runWithProgress(args, in: root, progress: progress)
    }

    // MARK: Partial staging

    public enum HunkAction: Sendable { case stage, unstage, discard }

    /// Applies one hunk (or selected lines of it). `diff` must come from the matching side:
    /// the unstaged diff for `.stage` / `.discard`, the staged diff for `.unstage`.
    public func apply(_ action: HunkAction, hunk: Int, lines: Set<Int>? = nil, in diff: FileDiff) async throws {
        let reverse = action != .stage
        guard let patch = diff.patch(hunk: hunk, selecting: lines, reverse: reverse) else { return }
        var args = ["apply", "--recount", "--whitespace=nowarn"]
        if action != .discard { args.append("--cached") }
        if reverse { args.append("--reverse") }
        args.append("-")
        _ = try await git.run(args, in: root, input: Data(patch.utf8))
    }

    // MARK: Discard

    /// Throws away unstaged changes: tracked files go back to their index version,
    /// untracked files are deleted.
    public func discard(_ changes: [FileChange]) async throws {
        let untracked = changes.filter { $0.kind == .untracked }.map(\.path)
        let tracked = changes.filter { $0.kind != .untracked }.map(\.path)
        if !tracked.isEmpty { _ = try await git.run(["restore", "--worktree", "--"] + tracked, in: root) }
        if !untracked.isEmpty { _ = try await git.run(["clean", "-f", "-q", "--"] + untracked, in: root) }
    }

    // MARK: Stashes

    public nonisolated func stashes() async throws -> [Stash] {
        let out = try await git.runString(["stash", "list", "--format=%gd%x1f%H%x1f%gs%x1f%ct"], in: root)
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { return nil }
            return Stash(name: f[0], id: f[1], message: f[2], date: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0))
        }
    }

    public func stash(message: String, includeUntracked: Bool) async throws {
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if !message.isEmpty { args += ["-m", message] }
        _ = try await git.run(args, in: root)
    }

    /// Resolves the entry's current `stash@{n}` from its commit id (indexes shift).
    private func ref(of stash: Stash) async throws -> String {
        guard let current = try await stashes().first(where: { $0.id == stash.id }) else {
            throw GitError(arguments: ["stash"], exitCode: 1, stderr: "That stash no longer exists")
        }
        return current.name
    }

    public func applyStash(_ stash: Stash, pop: Bool) async throws {
        _ = try await git.run(["stash", pop ? "pop" : "apply", try await ref(of: stash)], in: root)
    }

    public func dropStash(_ stash: Stash) async throws {
        _ = try await git.run(["stash", "drop", "-q", try await ref(of: stash)], in: root)
    }

    public nonisolated func stashFiles(_ stash: Stash) async throws -> [ChangedFile] {
        GitParse.nameStatus(try await git.run(["stash", "show", "--include-untracked", "-z", "--name-status", stash.id], in: root))
    }

    /// Patch for one file of a stash. Tracked changes are `stash^1..stash`; untracked
    /// files live in the stash's third parent (a root commit).
    public nonisolated func stashDiff(_ stash: Stash, file: ChangedFile) async throws -> String {
        var paths = [file.path]
        if let orig = file.origPath { paths.insert(orig, at: 0) }
        let tracked = try await git.runString(["diff", "-M", "--no-ext-diff", "\(stash.id)^1", stash.id, "--"] + paths, in: root)
        if !tracked.isEmpty { return tracked }
        let hasUntracked = (try? await git.run(["rev-parse", "-q", "--verify", "\(stash.id)^3"], in: root)) != nil
        guard hasUntracked else { return "" }
        return try await git.runString(["show", "--format=", "--no-ext-diff", "\(stash.id)^3", "--", file.path], in: root)
    }

    // MARK: Commit operations

    /// Lightweight tag when `message` is empty, annotated otherwise.
    public func createTag(_ name: String, at commit: String, message: String = "") async throws {
        if message.isEmpty {
            _ = try await git.run(["tag", name, commit], in: root)
        } else {
            _ = try await git.run(["tag", "-a", name, "-F", "-", commit], in: root, input: Data(message.utf8))
        }
    }

    public func deleteTag(_ name: String) async throws {
        _ = try await git.run(["tag", "-d", name], in: root)
    }

    public nonisolated func validateTagName(_ name: String) async -> String? {
        if name.isEmpty { return "Name is empty" }
        let ok = (try? await git.run(["check-ref-format", "refs/tags/\(name)"], in: root)) != nil
        return ok ? nil : "“\(name)” is not a valid tag name"
    }

    /// Merge commits are picked / reverted relative to their first parent.
    public func cherryPick(_ commit: Commit) async throws {
        _ = try await git.run(["cherry-pick"] + (commit.isMerge ? ["-m", "1"] : []) + [commit.id], in: root)
    }

    public func revert(_ commit: Commit) async throws {
        _ = try await git.run(["revert", "--no-edit"] + (commit.isMerge ? ["-m", "1"] : []) + [commit.id], in: root)
    }

    public enum ResetMode: String, Sendable, CaseIterable { case soft, mixed, hard }

    public func reset(_ mode: ResetMode, to commit: String) async throws {
        _ = try await git.run(["reset", "-q", "--\(mode.rawValue)", commit], in: root)
    }
}

extension GitError {
    public var isNotFullyMerged: Bool { stderr.contains("not fully merged") }
}
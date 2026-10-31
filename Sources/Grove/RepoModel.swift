import Foundation
import GroveCore
import Observation

enum SidebarItem: Hashable {
    case workingCopy
    case history
    case ref(String)
}

enum BranchSheet: Identifiable {
    case create(startPoint: String, label: String)
    case rename(Ref)

    var id: String {
        switch self {
        case .create(let start, _): "create:\(start)"
        case .rename(let ref): "rename:\(ref.id)"
        }
    }
}

struct CommitDetail {
    let commit: Commit
    let message: String
    let files: [ChangedFile]
}

struct ChangeEntry: Identifiable, Hashable {
    let change: FileChange
    let staged: Bool
    var id: String { (staged ? "S:" : "U:") + change.path }
    var letter: String {
        switch change.kind {
        case .untracked: "?"
        case .unmerged: "U"
        default: String(staged ? change.index : change.worktree)
        }
    }
}

@MainActor
@Observable
final class RepoModel {
    let url: URL
    private(set) var repo: Repository?
    var errorMessage: String?

    var sidebarSelection: SidebarItem? = .history {
        didSet { sidebarSelectionChanged() }
    }
    var showsWorkingCopy: Bool { sidebarSelection == .workingCopy }

    // History
    private(set) var rows: [CommitRow] = []
    private(set) var rowIndex: [String: Int] = [:]
    /// Bumped whenever `rows` is replaced (not appended), so the table reloads.
    private(set) var logGeneration = 0
    /// Bumped to ask the table to scroll to the selected commit.
    private(set) var scrollToken = 0
    private(set) var isLoadingLog = false
    private(set) var refs: [Ref] = []
    private(set) var currentBranch: String?

    var selectedCommitID: String? {
        didSet { if oldValue != selectedCommitID { loadCommitDetail() } }
    }
    private(set) var detail: CommitDetail?
    var selectedFileID: ChangedFile.ID? {
        didSet { if oldValue != selectedFileID { loadCommitFileDiff() } }
    }
    private(set) var commitDiff = ""

    // Working copy
    private(set) var changes: [FileChange] = []
    var selectedChangeID: ChangeEntry.ID? {
        didSet { if oldValue != selectedChangeID { loadWorkingDiff() } }
    }
    private(set) var workingDiff = ""
    var commitMessage = ""
    private(set) var isCommitting = false

    // Branch UI
    var branchSheet: BranchSheet?
    var pendingDelete: Ref?
    var forceDelete: Ref?
    var sidebarFilter = ""
    var expandedGroups: Set<String> = []
    private(set) var isBusy = false

    private var logTask: Task<Void, Never>?
    private var logRequest = 0
    @ObservationIgnored private var watcher: RepositoryWatcher?
    private var detailTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    var title: String { repo?.name ?? url.lastPathComponent }
    var stagedEntries: [ChangeEntry] { changes.filter(\.isStaged).map { ChangeEntry(change: $0, staged: true) } }
    var unstagedEntries: [ChangeEntry] { changes.filter(\.isUnstaged).map { ChangeEntry(change: $0, staged: false) } }

    func load() async {
        guard repo == nil else { return }
        do {
            let r = try await Repository.open(url)
            repo = r
            RecentRepositories.add(r.root)
            watcher = r.watch { [weak self] change in
                Task { @MainActor in await self?.filesChanged(change) }
            }
            await refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func refresh() async {
        await refreshRefsAndStatus()
        reloadLog()
    }

    private func filesChanged(_ change: RepositoryWatcher.Change) async {
        if change.contains(.refs) {
            await refresh()
        } else {
            await refreshRefsAndStatus()
        }
    }

    func refreshRefsAndStatus() async {
        guard let repo else { return }
        async let refs = repo.refs()
        async let branch = repo.currentBranch()
        async let status = repo.status()
        do {
            self.refs = try await refs
            self.currentBranch = await branch
            self.changes = try await status
            if let id = selectedChangeID, !(stagedEntries + unstagedEntries).contains(where: { $0.id == id }) {
                selectedChangeID = nil
            } else {
                loadWorkingDiff()
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: History

    private func reloadLog() {
        guard let repo else { return }
        logTask?.cancel()
        // Old rows stay on screen until the first new batch arrives (no flicker on refresh).
        logRequest += 1
        let request = logRequest
        isLoadingLog = true
        logTask = Task.detached(priority: .userInitiated) { [weak self] in
            let head = await repo.headID()
            var layout = GraphLayout(mainline: head)
            var batch: [CommitRow] = []
            var flushAt = 300  // small first batch: paint fast, then go big
            var first = true
            do {
                for try await record in repo.logRecords(includeHEAD: head != nil) {
                    guard let c = GitParse.commit(record) else { continue }
                    batch.append(CommitRow(commit: c, graph: layout.add(id: c.id, parents: c.parents)))
                    if batch.count >= flushAt {
                        let b = batch
                        batch.removeAll(keepingCapacity: true)
                        flushAt = 5000
                        await self?.receive(b, request: request, first: first, done: false)
                        first = false
                    }
                }
                await self?.receive(batch, request: request, first: first, done: true)
            } catch is CancellationError {
            } catch {
                await self?.logFailed(error, request: request)
            }
        }
    }

    private func receive(_ batch: [CommitRow], request: Int, first: Bool, done: Bool) {
        guard request == logRequest else { return }
        if first {
            rows = batch
            rowIndex = Dictionary(uniqueKeysWithValues: batch.enumerated().map { ($1.id, $0) })
            logGeneration += 1
        } else {
            let base = rows.count
            for (i, row) in batch.enumerated() { rowIndex[row.id] = base + i }
            rows.append(contentsOf: batch)
        }
        if first || done, selectedCommitID.map({ rowIndex[$0] == nil }) ?? true {
            // Selection vanished (amend, reset…) or never existed: pick the newest commit.
            if done || selectedCommitID == nil { selectedCommitID = rows.first?.id }
        }
        if done { isLoadingLog = false }
    }

    private func logFailed(_ error: Error, request: Int) {
        guard request == logRequest else { return }
        isLoadingLog = false
        errorMessage = "\(error)"
    }

    private func sidebarSelectionChanged() {
        guard case .ref(let id)? = sidebarSelection, let ref = refs.first(where: { $0.id == id }) else { return }
        jump(to: ref.target)
    }

    func jump(to commitID: String) {
        guard rowIndex[commitID] != nil else { return }
        selectedCommitID = commitID
        scrollToken += 1
    }

    private func loadCommitDetail() {
        detailTask?.cancel()
        guard let repo, let id = selectedCommitID, let idx = rowIndex[id] else {
            detail = nil
            selectedFileID = nil
            return
        }
        let commit = rows[idx].commit
        detailTask = Task { [weak self] in
            do {
                async let message = repo.message(of: commit.id)
                async let files = repo.changedFiles(in: commit)
                let d = CommitDetail(commit: commit, message: try await message, files: try await files)
                guard let self, !Task.isCancelled, self.selectedCommitID == commit.id else { return }
                self.detail = d
                self.selectedFileID = d.files.first?.id
                self.loadCommitFileDiff()
            } catch {
                if !Task.isCancelled { self?.errorMessage = "\(error)" }
            }
        }
    }

    private func loadCommitFileDiff() {
        diffTask?.cancel()
        guard let repo, let detail, let id = selectedFileID,
              let file = detail.files.first(where: { $0.id == id }) else {
            commitDiff = ""
            return
        }
        diffTask = Task { [weak self] in
            let text = (try? await repo.diff(of: file, in: detail.commit)) ?? ""
            guard let self, !Task.isCancelled else { return }
            self.commitDiff = text
        }
    }

    // MARK: Working copy

    private func entry(for id: ChangeEntry.ID?) -> ChangeEntry? {
        guard let id else { return nil }
        return (stagedEntries + unstagedEntries).first { $0.id == id }
    }

    private func loadWorkingDiff() {
        guard let repo, let e = entry(for: selectedChangeID) else {
            workingDiff = ""
            return
        }
        Task { [weak self] in
            let text = (try? await repo.workingDiff(of: e.change, staged: e.staged)) ?? ""
            guard let self, self.selectedChangeID == e.id else { return }
            self.workingDiff = text
        }
    }

    func stage(_ entries: [ChangeEntry]) async {
        await write { try await $0.stage(entries.map(\.change.path)) }
    }

    func unstage(_ entries: [ChangeEntry]) async {
        await write { try await $0.unstage(entries.map(\.change.path)) }
    }

    var canCommit: Bool {
        !isCommitting && !stagedEntries.isEmpty && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func commit() async {
        guard canCommit, let repo else { return }
        isCommitting = true
        defer { isCommitting = false }
        do {
            try await repo.commit(message: commitMessage)
            commitMessage = ""
            selectedCommitID = nil
            await refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func write(_ op: (Repository) async throws -> Void) async {
        guard let repo else { return }
        do {
            try await op(repo)
        } catch {
            errorMessage = "\(error)"
        }
        await refreshRefsAndStatus()
    }

    // MARK: Branches

    func ref(id: String) -> Ref? { refs.first { $0.id == id } }

    func isCurrent(_ ref: Ref) -> Bool { ref.kind == .branch && ref.name == currentBranch }

    func checkout(_ ref: Ref) async {
        guard !isCurrent(ref) else { return }
        await perform { try await $0.checkout(ref) }
    }

    func checkoutDetached(_ commitID: String) async {
        await perform { try await $0.checkoutDetached(commitID) }
    }

    func validateBranchName(_ name: String) async -> String? {
        guard let repo else { return nil }
        if let problem = await repo.validateBranchName(name) { return problem }
        if refs.contains(where: { $0.kind == .branch && $0.name == name }) { return "A branch named “\(name)” already exists" }
        return nil
    }

    /// Returns an error message to show in the sheet, nil on success.
    func createBranch(_ name: String, at startPoint: String, checkout: Bool) async -> String? {
        guard let repo else { return nil }
        do {
            try await repo.createBranch(name, at: startPoint, checkout: checkout)
        } catch {
            return "\(error)"
        }
        await refresh()
        return nil
    }

    func renameBranch(_ ref: Ref, to name: String) async -> String? {
        guard let repo else { return nil }
        do {
            try await repo.renameBranch(ref.name, to: name)
        } catch {
            return "\(error)"
        }
        if case .ref(ref.id)? = sidebarSelection { sidebarSelection = .ref("refs/heads/" + name) }
        await refresh()
        return nil
    }

    func deleteBranch(_ ref: Ref, force: Bool) async {
        guard let repo else { return }
        do {
            try await repo.deleteBranch(ref.name, force: force)
            if case .ref(ref.id)? = sidebarSelection { sidebarSelection = .history }
        } catch let e as GitError where e.isNotFullyMerged && !force {
            forceDelete = ref
        } catch {
            errorMessage = "\(error)"
        }
        await refresh()
    }

    /// Starting point for "New Branch": the selected commit in history, else HEAD.
    func beginNewBranch() {
        if !showsWorkingCopy, let id = selectedCommitID, let row = rowIndex[id] {
            let c = rows[row].commit
            branchSheet = .create(startPoint: c.id, label: "\(c.shortID) “\(c.subject)”")
        } else {
            branchSheet = .create(startPoint: "HEAD", label: currentBranch ?? "HEAD")
        }
    }

    /// Runs a write that can move HEAD or refs, then refreshes everything.
    private func perform(_ op: (Repository) async throws -> Void) async {
        guard let repo, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await op(repo)
        } catch {
            errorMessage = "\(error)"
        }
        await refresh()
    }
}
